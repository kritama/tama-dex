defmodule Tama.Dex.TestSupport.Cassettes do
  @moduledoc false

  # Builds and alters cassettes for tests, always under a test's tmp_dir.
  # None is committed.

  import Tama.Dex.TestSupport.Documents

  alias Exqlite.Sqlite3
  alias Tama.Dex.Cassette
  alias Tama.Dex.Cassette.Format
  alias Tama.Dex.Cassette.Reader
  alias Tama.Dex.Index
  alias Tama.Dex.Index.SQL

  @doc "Builds a cassette at `dir/file` and returns the build result."
  def build!(dir, file, documents, opts) do
    {:ok, built} = Cassette.build(documents, Path.join(dir, file), opts)
    built
  end

  @doc "An `opsmaru_incus` cassette holding the fixture's source plus `extra`."
  def incus!(dir, version, opts \\ []) do
    incus = fixture("profile/valid/opsmaru_incus.json")

    incus =
      case Keyword.get(opts, :drop) do
        nil -> incus
        id -> Map.update!(incus, "paths", &Map.delete(&1, "/operations/#{id}"))
      end

    native = document("opsmaru_native", Keyword.get(opts, :native, ["native_status"]))

    build!(dir, "opsmaru_incus-#{version}.tama-cassette", [incus, native],
      name: Keyword.get(opts, :name, "opsmaru_incus"),
      version: version
    )
  end

  @doc "A cassette of one source holding `count` generated operations."
  def bulk!(dir, name, count, version \\ "1.0.0") do
    ids = Enum.map(1..count, &"#{name}_op_#{String.pad_leading(Integer.to_string(&1), 4, "0")}")

    build!(dir, "#{name}-#{version}.tama-cassette", [document(name, ids, version: version)],
      name: name,
      version: version
    )
  end

  @doc "Runs SQL against a cassette file, as an attacker editing it would."
  def tamper!(path, statements) do
    {:ok, conn} = Sqlite3.open(path)

    try do
      Enum.each(List.wrap(statements), fn
        {sql, args} -> SQL.run!(conn, sql, args)
        sql -> SQL.execute!(conn, sql)
      end)
    after
      Sqlite3.close(conn)
    end

    path
  end

  @doc """
  Rewrites a cassette's manifest to another index schema version, with a
  matching content digest, as an older build would have written it.
  """
  def set_schema_version!(path, version) do
    {:ok, conn} = Sqlite3.open(path)

    try do
      [[name, cassette_version]] = SQL.query!(conn, "SELECT name, version FROM cassette_manifest")
      sources = SQL.query!(conn, "SELECT source, digest FROM cassette_documents")

      digest =
        Format.content_digest(
          name,
          cassette_version,
          version,
          Enum.map(sources, &List.to_tuple/1)
        )

      SQL.run!(
        conn,
        "UPDATE cassette_manifest SET index_schema_version = ?, content_digest = ?",
        [version, digest]
      )
    after
      Sqlite3.close(conn)
    end

    path
  end

  @doc "The file's SHA-256."
  def sha256!(path) do
    {:ok, sha256} = Reader.sha256(path)
    sha256
  end

  @doc "Holds the index's writer until `release/1`. Returns the writer's pid."
  def hold_writer!(index) do
    test = self()

    Task.start(fn ->
      Index.write(index, fn _conn ->
        send(test, {:holding, self()})

        receive do
          :release -> {:unchanged, :ok}
        end
      end)
    end)

    receive do
      {:holding, writer} -> writer
    after
      5_000 -> raise "the writer was not held"
    end
  end

  @doc "Releases a held writer."
  def release(writer), do: send(writer, :release)
end
