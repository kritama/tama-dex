defmodule Tama.Dex.Index.Connection do
  @moduledoc false

  # Opens the index's SQLite connections and owns the storage schema.
  #
  # The schema version covers both the table definitions and how rows are
  # derived from documents (canonical JSON, bundled schemas, schema digests
  # and FTS text). A database with any other version, or with tables but no
  # version, is recreated empty. It is never migrated in place.

  alias Exqlite.Sqlite3
  alias Tama.Dex.Index.SQL

  @schema_version 1
  @busy_timeout 5_000

  @tables """
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE cassettes (
    cassette TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('imported', 'local')),
    version TEXT,
    content_digest TEXT,
    file_sha256 TEXT,
    mode TEXT,
    loaded_at TEXT NOT NULL
  );
  CREATE TABLE sources (
    cassette TEXT NOT NULL REFERENCES cassettes(cassette) ON DELETE CASCADE,
    source TEXT NOT NULL,
    title TEXT NOT NULL,
    version TEXT NOT NULL,
    profile TEXT NOT NULL,
    digest TEXT NOT NULL,
    loaded_at TEXT NOT NULL,
    PRIMARY KEY (cassette, source)
  );
  CREATE TABLE operations (
    id INTEGER PRIMARY KEY,
    cassette TEXT NOT NULL,
    source TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    description TEXT NOT NULL,
    tags TEXT NOT NULL,
    scopes TEXT NOT NULL,
    destructive INTEGER NOT NULL,
    deprecated INTEGER NOT NULL,
    confirmation TEXT,
    bounds TEXT,
    identity TEXT,
    input_schema TEXT NOT NULL,
    input_schema_digest TEXT NOT NULL,
    success_schema TEXT NOT NULL,
    success_schema_digest TEXT NOT NULL,
    error_schema TEXT,
    error_schema_digest TEXT,
    extensions TEXT,
    UNIQUE (cassette, operation_id),
    FOREIGN KEY (cassette, source) REFERENCES sources(cassette, source) ON DELETE CASCADE
  );
  CREATE INDEX operations_source ON operations (cassette, source);
  CREATE VIRTUAL TABLE operations_fts USING fts5(
    operation_id, summary, tags, description, fields,
    tokenize = 'unicode61'
  );
  """

  @doc "The storage schema version this code writes."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Opens the write connection, creating the database file with mode 0600
  when it doesn't exist, and makes sure the storage schema is current.
  Returns the connection and, when the database was recreated, the version
  it had (`nil` when it had tables but no version).
  """
  @spec open_writer(String.t()) ::
          {:ok, SQL.conn(), {:recreated, term()} | :current} | {:error, term()}
  def open_writer(location) do
    with :ok <- create_file(location),
         {:ok, conn} <- open(location) do
      configure_writer(conn, location)
      {:ok, conn, ensure_schema(conn)}
    end
  end

  @doc "Opens the read connection. It can't write."
  @spec open_reader(String.t()) :: {:ok, SQL.conn()} | {:error, term()}
  def open_reader(location) do
    with {:ok, conn} <- open(location) do
      SQL.execute!(conn, "PRAGMA query_only = ON")
      {:ok, conn}
    end
  end

  @doc "Closes a connection."
  @spec close(SQL.conn()) :: :ok
  def close(conn) do
    _result = Sqlite3.close(conn)
    :ok
  end

  defp create_file("file:" <> _memdb), do: :ok

  defp create_file(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)
        File.chmod(path, 0o600)

      {:error, :eexist} ->
        :ok

      {:error, reason} ->
        {:error, {:open, reason}}
    end
  end

  defp open(location) do
    case Sqlite3.open(location) do
      {:ok, conn} ->
        :ok = Sqlite3.set_busy_timeout(conn, @busy_timeout)
        _result = Sqlite3.enable_load_extension(conn, false)
        {:ok, conn}

      {:error, reason} ->
        {:error, {:open, reason}}
    end
  end

  defp configure_writer(conn, "file:" <> _memdb) do
    SQL.execute!(conn, "PRAGMA foreign_keys = ON")
  end

  defp configure_writer(conn, _path) do
    SQL.execute!(conn, "PRAGMA journal_mode = WAL")
    SQL.execute!(conn, "PRAGMA synchronous = NORMAL")
    SQL.execute!(conn, "PRAGMA foreign_keys = ON")
  end

  defp ensure_schema(conn) do
    case stored_version(conn) do
      {:ok, @schema_version} ->
        :current

      :empty ->
        create(conn)
        :current

      {:ok, other} ->
        recreate(conn)
        {:recreated, other}
    end
  end

  defp stored_version(conn) do
    tables = SQL.query!(conn, "SELECT name FROM sqlite_master WHERE type = 'table'")

    cond do
      tables == [] ->
        :empty

      ["meta"] in tables ->
        case SQL.query!(conn, "SELECT value FROM meta WHERE key = 'schema_version'") do
          [[value]] -> {:ok, parse_version(value)}
          [] -> {:ok, nil}
        end

      true ->
        {:ok, nil}
    end
  end

  defp parse_version(value) do
    case Integer.parse(to_string(value)) do
      {version, ""} -> version
      _other -> value
    end
  end

  defp create(conn) do
    SQL.transaction(conn, fn ->
      SQL.execute!(conn, @tables)

      SQL.run!(conn, "INSERT INTO meta (key, value) VALUES ('schema_version', ?)", [
        Integer.to_string(@schema_version)
      ])

      {:commit, :ok}
    end)
  end

  defp recreate(conn) do
    SQL.execute!(conn, "PRAGMA foreign_keys = OFF")

    SQL.transaction(conn, fn ->
      drop_all(conn)
      {:commit, :ok}
    end)

    SQL.execute!(conn, "PRAGMA foreign_keys = ON")
    create(conn)
  end

  # Views and triggers first, then virtual tables (which drop their own
  # shadow tables), then whatever tables remain.
  defp drop_all(conn) do
    for [type, name] <- objects(conn, "type IN ('view', 'trigger')") do
      SQL.execute!(conn, "DROP #{String.upcase(type)} IF EXISTS #{quote_name(name)}")
    end

    for [_type, name] <- objects(conn, "type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%'") do
      SQL.execute!(conn, "DROP TABLE IF EXISTS #{quote_name(name)}")
    end

    for [_type, name] <- objects(conn, "type = 'table'") do
      SQL.execute!(conn, "DROP TABLE IF EXISTS #{quote_name(name)}")
    end
  end

  defp objects(conn, condition) do
    SQL.query!(
      conn,
      "SELECT type, name FROM sqlite_master WHERE #{condition} AND name NOT LIKE 'sqlite_%'"
    )
  end

  defp quote_name(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")
end
