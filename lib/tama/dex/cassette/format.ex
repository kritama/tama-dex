defmodule Tama.Dex.Cassette.Format do
  @moduledoc false

  # The `tama-cassette/1` file format: the storage schema's tables holding
  # one cassette, plus a one-row manifest and each source's canonical
  # document.
  #
  # The content digest is the SHA-256 of canonical JSON naming the format,
  # the cassette name and version, the index schema version and the sorted
  # `[source, document digest]` pairs. It ignores the tama-dex and SQLite
  # versions and the file's bytes, so the same documents give the same
  # content digest.

  alias Exqlite.Sqlite3
  alias Tama.Dex.Index.Connection
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.JSON

  @format "tama-cassette/1"

  # Cassettes store no wall-clock time. Import sets `loaded_at`.
  @epoch "1970-01-01T00:00:00Z"

  @tables """
  CREATE TABLE cassette_manifest (
    format TEXT NOT NULL,
    name TEXT NOT NULL,
    version TEXT NOT NULL,
    tama_dex_version TEXT NOT NULL,
    index_schema_version INTEGER NOT NULL,
    sqlite_version TEXT NOT NULL,
    profile TEXT NOT NULL,
    content_digest TEXT NOT NULL
  );
  CREATE TABLE cassette_documents (
    source TEXT PRIMARY KEY,
    digest TEXT NOT NULL,
    document TEXT NOT NULL
  );
  """

  @cassette_tables ["cassette_manifest", "cassette_documents"]
  @fts_shadow "operations_fts_"

  @doc "The format name."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The `loaded_at` value a cassette's rows hold."
  @spec epoch() :: String.t()
  def epoch, do: @epoch

  @doc "Creates the manifest and document tables."
  @spec create_tables(SQL.conn()) :: :ok
  def create_tables(conn), do: SQL.execute!(conn, @tables)

  @doc "The content digest of a cassette."
  @spec content_digest(String.t(), String.t(), integer(), [{String.t(), String.t()}]) ::
          String.t()
  def content_digest(name, version, index_schema_version, sources) do
    %{
      "format" => @format,
      "name" => name,
      "version" => version,
      "index_schema_version" => index_schema_version,
      "sources" => sources |> Enum.sort() |> Enum.map(fn {source, digest} -> [source, digest] end)
    }
    |> JSON.encode!()
    |> JSON.sha256()
  end

  @doc """
  Conflicting operation IDs across documents: for each source after the
  first to use an ID, `%{source, operation_ids}`.
  """
  @spec duplicate_operations([Tama.Dex.Document.t()]) :: [map()]
  def duplicate_operations(documents) do
    {conflicts, _owners} =
      Enum.reduce(documents, {[], MapSet.new()}, fn document, {conflicts, owners} ->
        ids = Enum.map(document.operations, & &1.operation_id)

        conflicts =
          case Enum.filter(ids, &MapSet.member?(owners, &1)) do
            [] -> conflicts
            taken -> [%{source: document.source, operation_ids: taken} | conflicts]
          end

        {conflicts, MapSet.union(owners, MapSet.new(ids))}
      end)

    Enum.reverse(conflicts)
  end

  @doc """
  The `sqlite_master` objects of a cassette of this index schema version, as
  `{type, name, table, sql}`. FTS5 shadow tables are compared by name only,
  since SQLite writes their definitions.
  """
  @spec expected_objects() :: [tuple()]
  def expected_objects do
    key = {__MODULE__, :objects, Connection.schema_version()}

    case :persistent_term.get(key, nil) do
      nil ->
        objects = build_expected_objects()
        :persistent_term.put(key, objects)
        objects

      objects ->
        objects
    end
  end

  @doc "The expected objects of the manifest and document tables alone."
  @spec cassette_objects() :: [tuple()]
  def cassette_objects do
    Enum.filter(expected_objects(), fn {_type, _name, table, _sql} ->
      table in @cassette_tables
    end)
  end

  @doc "Normalizes a `sqlite_master` row for comparison."
  @spec object([term()]) :: tuple()
  def object([type, name, table, sql]) do
    if is_binary(table) and String.starts_with?(table, @fts_shadow),
      do: {type, name, table, nil},
      else: {type, name, table, sql}
  end

  defp build_expected_objects do
    location = "file:/tama-dex-cassette-#{System.unique_integer([:positive])}?vfs=memdb"
    {:ok, conn} = Sqlite3.open(location)

    try do
      Connection.create_tables(conn)
      create_tables(conn)

      conn
      |> SQL.query!("SELECT type, name, tbl_name, sql FROM sqlite_master")
      |> Enum.map(&object/1)
      |> Enum.sort()
    after
      Sqlite3.close(conn)
    end
  end
end
