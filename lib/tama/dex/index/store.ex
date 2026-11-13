defmodule Tama.Dex.Index.Store do
  @moduledoc false

  # Rows of the storage schema, derived from validated documents.
  #
  # Write functions run on the writer's connection and return
  # `{:changed, reply}` after committing a change, or `{:unchanged, reply}`.
  # JSON columns hold canonical JSON, and schema columns hold the bundled
  # schemas with the SHA-256 of their text as the compiled-schema cache key.

  alias Tama.Dex.Document
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.JSON
  alias Tama.Dex.Operation

  @doc """
  Installs a document as one source of a local cassette, replacing that
  source's previous entries in one transaction.
  """
  @spec load(SQL.conn(), String.t(), Document.t()) ::
          {:changed | :unchanged, {:ok, map()} | {:error, term()}}
  def load(conn, cassette, %Document{} = document) do
    SQL.transaction(conn, fn ->
      with :ok <- check_kind(conn, cassette, "local"),
           :ok <- check_changed(conn, cassette, document),
           :ok <- check_duplicates(conn, cassette, document) do
        replace_source(conn, cassette, document)
        {:commit, {:changed, {:ok, loaded(cassette, document, true)}}}
      else
        :unchanged -> {:rollback, {:unchanged, {:ok, loaded(cassette, document, false)}}}
        {:error, _reason} = error -> {:rollback, {:unchanged, error}}
      end
    end)
  end

  defp loaded(cassette, document, changed) do
    %{
      cassette: cassette,
      source: document.source,
      operations: length(document.operations),
      changed: changed
    }
  end

  defp check_kind(conn, cassette, kind) do
    case SQL.query!(conn, "SELECT kind FROM cassettes WHERE cassette = ?", [cassette]) do
      [] -> :ok
      [[^kind]] -> :ok
      [[_other]] -> {:error, :cassette_conflict}
    end
  end

  defp check_changed(conn, cassette, document) do
    case SQL.query!(
           conn,
           "SELECT digest, profile FROM sources WHERE cassette = ? AND source = ?",
           [cassette, document.source]
         ) do
      [[digest, profile]] when digest == document.digest and profile == document.profile ->
        :unchanged

      _other ->
        :ok
    end
  end

  defp check_duplicates(conn, cassette, document) do
    ids = JSON.encode!(Enum.map(document.operations, & &1.operation_id))

    rows =
      SQL.query!(
        conn,
        """
        SELECT source, operation_id FROM operations
        WHERE cassette = ? AND source <> ?
          AND operation_id IN (SELECT value FROM json_each(?))
        ORDER BY source, operation_id
        """,
        [cassette, document.source, ids]
      )

    case rows do
      [] ->
        :ok

      rows ->
        conflicts =
          rows
          |> Enum.chunk_by(&hd/1)
          |> Enum.map(fn [[source, _id] | _rest] = group ->
            %{source: source, operation_ids: Enum.map(group, &List.last/1)}
          end)

        {:error, {:duplicate_operation, conflicts}}
    end
  end

  defp replace_source(conn, cassette, document) do
    now = now()

    SQL.run!(
      conn,
      """
      INSERT INTO cassettes (cassette, kind, loaded_at) VALUES (?, 'local', ?)
      ON CONFLICT (cassette) DO UPDATE SET loaded_at = excluded.loaded_at
      """,
      [cassette, now]
    )

    delete_operations(conn, "cassette = ? AND source = ?", [cassette, document.source])

    SQL.run!(
      conn,
      """
      INSERT INTO sources (cassette, source, title, version, profile, digest, loaded_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (cassette, source) DO UPDATE SET
        title = excluded.title, version = excluded.version, profile = excluded.profile,
        digest = excluded.digest, loaded_at = excluded.loaded_at
      """,
      [
        cassette,
        document.source,
        document.title,
        document.version,
        document.profile,
        document.digest,
        now
      ]
    )

    Enum.each(document.operations, &insert_operation(conn, cassette, &1))
  end

  defp insert_operation(conn, cassette, %Operation{} = operation) do
    {input, input_digest} = schema_text(operation.input_schema)
    {success, success_digest} = schema_text(operation.success_schema)
    {error, error_digest} = schema_text(operation.error_schema)

    id =
      SQL.insert!(
        conn,
        """
        INSERT INTO operations (
          cassette, source, operation_id, summary, description, tags, scopes,
          destructive, deprecated, confirmation, bounds, identity,
          input_schema, input_schema_digest, success_schema, success_schema_digest,
          error_schema, error_schema_digest, extensions
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          cassette,
          operation.source,
          operation.operation_id,
          operation.summary,
          operation.description,
          JSON.encode!(operation.tags),
          JSON.encode!(operation.scopes),
          operation.destructive,
          operation.deprecated,
          optional_json(operation.confirmation),
          optional_json(operation.bounds),
          optional_json(operation.identity),
          input,
          input_digest,
          success,
          success_digest,
          error,
          error_digest,
          optional_json(operation.extensions)
        ]
      )

    SQL.run!(
      conn,
      """
      INSERT INTO operations_fts (rowid, operation_id, summary, tags, description, fields)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        operation.operation_id,
        operation.summary,
        Enum.join(operation.tags, " "),
        operation.description,
        fields_text(operation.fields)
      ]
    )
  end

  defp schema_text(nil), do: {nil, nil}

  defp schema_text(schema) do
    text = JSON.encode!(schema)
    {text, JSON.sha256(text)}
  end

  defp optional_json(empty) when empty in [nil, [], %{}], do: nil
  defp optional_json(value), do: JSON.encode!(value)

  # Top-level input property names and their descriptions, so a field name
  # such as `fingerprint` finds the operations that take it.
  defp fields_text(fields) do
    Enum.map_join(fields, " ", fn
      %{name: name, description: nil} -> name
      %{name: name, description: description} -> name <> " " <> description
    end)
  end

  @doc "Removes a whole cassette. Unknown cassettes are a no-op."
  @spec unload(SQL.conn(), String.t()) :: {:changed | :unchanged, :ok}
  def unload(conn, cassette) do
    SQL.transaction(conn, fn ->
      case SQL.query!(conn, "SELECT 1 FROM cassettes WHERE cassette = ?", [cassette]) do
        [] ->
          {:rollback, {:unchanged, :ok}}

        [_row] ->
          delete_operations(conn, "cassette = ?", [cassette])
          SQL.run!(conn, "DELETE FROM cassettes WHERE cassette = ?", [cassette])
          {:commit, {:changed, :ok}}
      end
    end)
  end

  # Operations and their FTS rows are written and deleted together.
  defp delete_operations(conn, condition, args) do
    SQL.run!(
      conn,
      "DELETE FROM operations_fts WHERE rowid IN (SELECT id FROM operations WHERE #{condition})",
      args
    )

    SQL.run!(conn, "DELETE FROM operations WHERE #{condition}", args)
  end

  @doc "Every installed cassette with its sources, ordered by name."
  @spec cassettes(SQL.conn()) :: [map()]
  def cassettes(conn) do
    sources =
      conn
      |> SQL.query!("""
      SELECT s.cassette, s.source, s.title, s.version, s.profile, s.digest, s.loaded_at,
             (SELECT count(*) FROM operations o
              WHERE o.cassette = s.cassette AND o.source = s.source)
      FROM sources s ORDER BY s.cassette, s.source
      """)
      |> Enum.group_by(&hd/1, fn [_cassette, source, title, version, profile, digest, at, count] ->
        %{
          source: source,
          title: title,
          version: version,
          profile: profile,
          digest: digest,
          operations: count,
          loaded_at: timestamp(at)
        }
      end)

    conn
    |> SQL.query!("""
    SELECT cassette, kind, version, content_digest, mode, loaded_at
    FROM cassettes ORDER BY cassette
    """)
    |> Enum.map(fn [cassette, kind, version, digest, mode, at] ->
      %{
        cassette: cassette,
        kind: kind(kind),
        version: version,
        status: :ready,
        mode: mode(mode),
        digest: digest,
        loaded_at: timestamp(at),
        sources: Map.get(sources, cassette, [])
      }
    end)
  end

  @doc "The digests of every stored schema."
  @spec schema_digests(SQL.conn()) :: MapSet.t(String.t())
  def schema_digests(conn) do
    conn
    |> SQL.query!("""
    SELECT input_schema_digest FROM operations
    UNION SELECT success_schema_digest FROM operations
    UNION SELECT error_schema_digest FROM operations WHERE error_schema_digest IS NOT NULL
    """)
    |> MapSet.new(&hd/1)
  end

  defp kind("local"), do: :local
  defp kind("imported"), do: :imported

  defp mode(nil), do: nil
  defp mode("copy"), do: :copy
  defp mode("rebuild"), do: :rebuild

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp timestamp(text) do
    {:ok, datetime, 0} = DateTime.from_iso8601(text)
    datetime
  end
end
