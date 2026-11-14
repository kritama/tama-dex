defmodule Tama.Dex.Cassette.Import do
  @moduledoc false

  # Installs a verified cassette, run as a tracked job on the index's write
  # connection.
  #
  # The whole cassette is replaced in one transaction. Copy mode, used only
  # under a matching host pin and the same index schema version, copies the
  # prebuilt rows through the connection verification opened on its
  # in-memory snapshot, so they come from the bytes that were hashed and
  # verified, giving operations new IDs and
  # their FTS rows those IDs. Rebuild mode, used otherwise, writes each
  # verified document as a load would, so an unpinned cassette can't install
  # rows that differ from its documents.

  alias Tama.Dex.Cassette.Reader
  alias Tama.Dex.Index.Connection
  alias Tama.Dex.Index.Job
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.Index.Store
  alias Tama.Dex.Telemetry

  @operation_columns """
  source, operation_id, summary, description, tags, scopes, destructive, deprecated,
  confirmation, bounds, identity, input_schema, input_schema_digest, success_schema,
  success_schema_digest, error_schema, error_schema_digest, extensions
  """

  @insert_operation """
  INSERT INTO operations (cassette, #{@operation_columns})
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  """

  @doc """
  Verifies and installs a cassette under `options.name`. Options: `:name`,
  `:pin` (or nil), `:limits`. Emits the `[:tama_dex, :import]` span.
  """
  @spec run(SQL.conn(), String.t(), map(), Job.t()) ::
          {:changed | :unchanged, {:ok, map()} | {:error, term()}}
  def run(conn, path, options, job) do
    Telemetry.span([:tama_dex, :import], %{cassette: options.name}, fn ->
      result = Job.guard(fn -> install(conn, path, options, job) end)
      {result, metadata(options.name, result)}
    end)
  end

  defp install(conn, path, options, job) do
    opts = [sha256: options.pin, limits: options.limits, job: job]

    case Reader.with_verified(path, opts, &install(conn, &1, &2, options, job)) do
      {:error, _reason} = error -> {:unchanged, error}
      written -> written
    end
  end

  defp install(conn, cassette, verified, options, job) do
    with :ok <- check_name(verified.manifest, options),
         :ok <- Store.check_kind(conn, options.name, "imported") do
      Job.progress(job, 0, length(verified.documents))

      if unchanged?(conn, options.name, verified.manifest) do
        {:unchanged, {:ok, result(conn, options.name, verified, false)}}
      else
        mode = mode(verified, options.pin)
        replace(conn, cassette, options.name, verified, mode, job)
        {:changed, {:ok, result(conn, options.name, verified, true)}}
      end
    end
  end

  # The installed name was read from the manifest before the job was
  # queued; a file that changed since then is rejected.
  defp check_name(%{name: name}, %{as: nil, name: name}), do: :ok
  defp check_name(_manifest, %{as: nil}), do: {:error, :invalid_manifest}
  defp check_name(_manifest, _options), do: :ok

  defp unchanged?(conn, name, manifest) do
    SQL.query!(conn, "SELECT content_digest FROM cassettes WHERE cassette = ?", [name]) ==
      [[manifest.content_digest]]
  end

  defp mode(verified, pin) do
    if pin != nil and verified.manifest.index_schema_version == Connection.schema_version(),
      do: :copy,
      else: :rebuild
  end

  defp replace(conn, cassette, name, verified, :copy, job) do
    transaction(conn, name, verified, :copy, fn now ->
      copy(conn, cassette, name, now, job)
    end)

    Job.progress(job, length(verified.documents), length(verified.documents))
  end

  defp replace(conn, _cassette, name, verified, :rebuild, job) do
    total = length(verified.documents)

    transaction(conn, name, verified, :rebuild, fn now ->
      verified.documents
      |> Enum.with_index(1)
      |> Enum.each(fn {document, done} ->
        Store.write_source(conn, name, document, now, job)
        Job.progress(job, done, total)
      end)

      Job.checkpoint(job)
    end)
  end

  defp transaction(conn, name, verified, mode, write) do
    manifest = verified.manifest
    now = Store.now()

    SQL.transaction(conn, fn ->
      Store.clear(conn, name)

      SQL.run!(
        conn,
        """
        INSERT INTO cassettes (cassette, kind, version, content_digest, file_sha256, mode, loaded_at)
        VALUES (?, 'imported', ?, ?, ?, ?, ?)
        ON CONFLICT (cassette) DO UPDATE SET
          version = excluded.version, content_digest = excluded.content_digest,
          file_sha256 = excluded.file_sha256, mode = excluded.mode,
          loaded_at = excluded.loaded_at
        """,
        [
          name,
          manifest.version,
          manifest.content_digest,
          verified.sha256,
          Atom.to_string(mode),
          now
        ]
      )

      write.(now)
      {:commit, :ok}
    end)
  end

  # Copies the pinned cassette's rows. Operations get new IDs, and each FTS
  # row is inserted under its operation's new ID.
  defp copy(conn, cassette, name, now, job) do
    for [source, title, version, profile, digest] <-
          SQL.query!(
            cassette,
            "SELECT source, title, version, profile, digest FROM sources ORDER BY source"
          ) do
      SQL.run!(
        conn,
        """
        INSERT INTO sources (cassette, source, title, version, profile, digest, loaded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [name, source, title, version, profile, digest, now]
      )
    end

    search =
      cassette
      |> SQL.query!(
        "SELECT rowid, operation_id, summary, tags, description, fields FROM operations_fts"
      )
      |> Map.new(fn [rowid | columns] -> {rowid, columns} end)

    for [id | columns] <-
          SQL.query!(cassette, "SELECT id, #{@operation_columns} FROM operations ORDER BY id") do
      Job.checkpoint(job)
      new_id = SQL.insert!(conn, @insert_operation, [name | columns])

      SQL.run!(
        conn,
        """
        INSERT INTO operations_fts (rowid, operation_id, summary, tags, description, fields)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [new_id | Map.fetch!(search, id)]
      )
    end

    :ok
  end

  defp result(conn, name, verified, changed) do
    [[mode]] = SQL.query!(conn, "SELECT mode FROM cassettes WHERE cassette = ?", [name])
    manifest = verified.manifest

    %{
      cassette: name,
      version: manifest.version,
      digest: manifest.content_digest,
      mode: String.to_existing_atom(mode),
      changed: changed,
      sources:
        Enum.map(verified.documents, &%{source: &1.source, operations: length(&1.operations)})
    }
  end

  defp metadata(name, {_changed, {:ok, result}}) do
    %{
      cassette: name,
      version: result.version,
      mode: result.mode,
      changed: result.changed,
      sources: length(result.sources),
      operations: Enum.sum_by(result.sources, & &1.operations),
      result: :ok
    }
  end

  defp metadata(name, {_changed, {:error, reason}}) do
    %{cassette: name, result: error_kind(reason)}
  end

  defp error_kind({kind, _detail}), do: kind
  defp error_kind({kind, _source, _issues}), do: kind
  defp error_kind(kind), do: kind
end
