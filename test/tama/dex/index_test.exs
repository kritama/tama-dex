defmodule Tama.Dex.IndexTest do
  use ExUnit.Case, async: true

  import Tama.Dex.TestSupport.Documents
  import Tama.Dex.TestSupport.Telemetry

  alias Exqlite.Sqlite3
  alias Tama.Dex.Index
  alias Tama.Dex.Index.SQL

  @moduletag :tmp_dir

  defp start_index!(opts) do
    start_supervised!({Index, opts}, id: make_ref())
  end

  defp rows(index, sql, args \\ []), do: Index.read(index, &SQL.query!(&1, sql, args))

  defp operation_ids(index, cassette) do
    index
    |> rows("SELECT operation_id FROM operations WHERE cassette = ? ORDER BY operation_id", [
      cassette
    ])
    |> List.flatten()
  end

  # Marks a cassette as imported, standing in for import/3.
  defp put_imported(index, cassette) do
    Index.write(index, fn conn ->
      SQL.run!(
        conn,
        "INSERT INTO cassettes (cassette, kind, version, loaded_at) VALUES (?, 'imported', '1.0.0', ?)",
        [cassette, DateTime.to_iso8601(DateTime.utc_now())]
      )

      {:changed, :ok}
    end)
  end

  describe "starting" do
    test "a missing or invalid path fails with an argument error and creates nothing", %{
      tmp_dir: tmp_dir
    } do
      assert_raise ArgumentError, ~r/needs a :path/, fn -> Index.start_link([]) end
      assert_raise ArgumentError, ~r/file path or :memory/, fn -> Index.start_link(path: 42) end
      assert_raise ArgumentError, ~r/file path or :memory/, fn -> Index.start_link(path: "") end
      assert File.ls!(tmp_dir) == []
    end

    test "limits can only lower the profile's", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "index.sqlite3")

      assert_raise ArgumentError, ~r/can't exceed/, fn ->
        Index.start_link(path: path, limits: [max_operations: 2000])
      end

      assert_raise ArgumentError, ~r/unknown limit/, fn ->
        Index.start_link(path: path, limits: [max_things: 1])
      end

      assert_raise ArgumentError, ~r/positive integers/, fn ->
        Index.start_link(path: path, limits: [max_operations: 0])
      end

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Index.start_link(path: path, limits: :none)
      end

      refute File.exists?(path)
    end

    test "a new database file is created with mode 0600 in WAL mode", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "index.sqlite3")
      index = start_index!(path: path)

      {:ok, _loaded} = Tama.Dex.load(index, document("alpha", ["a_one"]), cassette: "alpha")

      for file <- [path, path <> "-wal", path <> "-shm"] do
        assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600, file
      end

      assert rows(index, "PRAGMA journal_mode") == [["wal"]]
    end

    test "a relative path is expanded from the working directory", %{tmp_dir: tmp_dir} do
      File.cd!(tmp_dir, fn ->
        start_index!(path: "relative.sqlite3")
        assert File.exists?(Path.join(tmp_dir, "relative.sqlite3"))
      end)
    end

    test "a database file in a missing directory fails to start", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      path = Path.join([tmp_dir, "missing", "index.sqlite3"])
      assert {:error, {:open, :enoent}} = Index.start_link(path: path)
    end

    test "the index can be registered under a name" do
      start_index!(path: :memory, name: :named_test_index)
      assert Tama.Dex.cassettes(:named_test_index) == []
    end

    test "each in-memory index is its own database" do
      first = start_index!(path: :memory)
      second = start_index!(path: :memory)

      {:ok, _loaded} = Tama.Dex.load(first, document("alpha", ["a_one"]), cassette: "alpha")

      assert [%{cassette: "alpha"}] = Tama.Dex.cassettes(first)
      assert Tama.Dex.cassettes(second) == []
    end

    test "the read connection can't write" do
      index = start_index!(path: :memory)

      assert_raise SQL.Error, ~r/readonly|read-only|query_only/i, fn ->
        Index.read(index, &SQL.run!(&1, "DELETE FROM cassettes"))
      end
    end

    test "a job that raises fails in the caller, not the index" do
      index = start_index!(path: :memory)

      assert_raise RuntimeError, "boom", fn -> Index.read(index, fn _conn -> raise "boom" end) end
      assert catch_throw(Index.write(index, fn _conn -> throw(:oops) end)) == :oops
      assert catch_exit(Index.read(index, fn _conn -> exit(:gone) end)) == :gone

      assert Tama.Dex.cassettes(index) == []
    end
  end

  describe "cassette namespaces" do
    setup do
      %{index: start_index!(path: :memory)}
    end

    test "the same operation name may be installed in two cassettes", %{index: index} do
      assert {:ok, %{changed: true}} =
               Tama.Dex.load(index, document("macus", ["list_instances"]), cassette: "macus")

      assert {:ok, %{changed: true}} =
               Tama.Dex.load(index, document("opsmaru_incus", ["list_instances"]),
                 cassette: "opsmaru_incus"
               )

      assert operation_ids(index, "macus") == ["list_instances"]
      assert operation_ids(index, "opsmaru_incus") == ["list_instances"]

      assert rows(index, "SELECT cassette, source FROM operations ORDER BY cassette") == [
               ["macus", "macus"],
               ["opsmaru_incus", "opsmaru_incus"]
             ]
    end

    test "the same source may be loaded into two cassettes", %{index: index} do
      doc = document("shared", ["s_one"])

      assert {:ok, %{cassette: "first"}} = Tama.Dex.load(index, doc, cassette: "first")

      assert {:ok, %{cassette: "second", changed: true}} =
               Tama.Dex.load(index, doc, cassette: "second")

      assert Enum.map(Tama.Dex.cassettes(index), & &1.cassette) == ["first", "second"]
    end

    test "loading into an imported cassette's name fails with cassette_conflict", %{index: index} do
      :ok = put_imported(index, "opsmaru_incus")
      before = Tama.Dex.cassettes(index)

      assert {:error, :cassette_conflict} =
               Tama.Dex.load(index, document("opsmaru_incus", ["x_one"]),
                 cassette: "opsmaru_incus"
               )

      assert Tama.Dex.cassettes(index) == before
      assert operation_ids(index, "opsmaru_incus") == []
    end

    test "a change to one cassette leaves the others untouched", %{index: index} do
      {:ok, _loaded} =
        Tama.Dex.load(index, document("alpha", ["a_one", "a_two"]), cassette: "alpha")

      {:ok, _loaded} =
        Tama.Dex.load(index, document("beta", ["b_one", "b_two"]), cassette: "beta")

      snapshot = fn ->
        {rows(index, "SELECT * FROM operations WHERE cassette = 'beta' ORDER BY id"),
         rows(index, "SELECT * FROM sources WHERE cassette = 'beta'"),
         rows(index, "SELECT * FROM cassettes WHERE cassette = 'beta'"),
         rows(
           index,
           "SELECT rowid, * FROM operations_fts WHERE rowid IN (SELECT id FROM operations WHERE cassette = 'beta')"
         )}
      end

      beta = snapshot.()

      {:ok, %{changed: true}} =
        Tama.Dex.load(index, document("alpha", ["a_three"], version: "2.0.0"), cassette: "alpha")

      assert snapshot.() == beta
      :ok = Tama.Dex.unload(index, "alpha")
      assert snapshot.() == beta
    end

    test "unload removes a whole cassette and its search rows", %{index: index} do
      {:ok, _loaded} = Tama.Dex.load(index, document("alpha", ["a_one"]), cassette: "alpha")
      {:ok, _loaded} = Tama.Dex.load(index, document("gamma", ["g_one"]), cassette: "alpha")
      {:ok, _loaded} = Tama.Dex.load(index, document("beta", ["b_one"]), cassette: "beta")

      assert :ok = Tama.Dex.unload(index, "alpha")
      assert Enum.map(Tama.Dex.cassettes(index), & &1.cassette) == ["beta"]
      assert rows(index, "SELECT count(*) FROM sources") == [[1]]
      assert rows(index, "SELECT operation_id FROM operations_fts") == [["b_one"]]

      assert :ok = Tama.Dex.unload(index, "alpha")
    end

    test "cassette names are validated", %{index: index} do
      doc = document("alpha", ["a_one"])

      assert_raise ArgumentError, ~r/:cassette name is required/, fn ->
        Tama.Dex.load(index, doc, [])
      end

      for name <- ["Alpha", "1alpha", "al-pha", "", String.duplicate("a", 65), :alpha] do
        assert_raise ArgumentError, ~r/invalid cassette name/, fn ->
          Tama.Dex.load(index, doc, cassette: name)
        end
      end

      assert_raise ArgumentError, fn -> Tama.Dex.unload(index, "Bad") end
      assert {:ok, _loaded} = Tama.Dex.load(index, doc, cassette: String.duplicate("a", 64))
    end

    test "cassettes reports each cassette and its sources", %{index: index} do
      {:ok, _loaded} =
        Tama.Dex.load(index, document("alpha", ["a_one", "a_two"], version: "0.3.0"),
          cassette: "local"
        )

      {:ok, _loaded} = Tama.Dex.load(index, document("beta", ["b_one"]), cassette: "local")

      assert [cassette] = Tama.Dex.cassettes(index)

      assert %{
               cassette: "local",
               kind: :local,
               version: nil,
               status: :ready,
               mode: nil,
               digest: nil,
               loaded_at: %DateTime{}
             } = cassette

      assert [alpha, beta] = cassette.sources

      assert %{source: "alpha", version: "0.3.0", operations: 2, profile: "tama-operations/1"} =
               alpha

      assert alpha.title == "alpha operations"
      assert alpha.digest =~ ~r/^[0-9a-f]{64}$/
      assert %DateTime{} = alpha.loaded_at
      assert %{source: "beta", operations: 1} = beta
    end
  end

  describe "local cassette loading" do
    setup do
      %{index: start_index!(path: :memory)}
    end

    test "a source is replaced atomically", %{index: index} do
      {:ok, %{operations: 2}} =
        Tama.Dex.load(index, document("macus", ["runtime_start", "runtime_stop"]),
          cassette: "macus"
        )

      {:ok, %{operations: 2, changed: true}} =
        Tama.Dex.load(
          index,
          document("macus", ["runtime_start", "runtime_status"], version: "2.0.0"),
          cassette: "macus"
        )

      assert operation_ids(index, "macus") == ["runtime_start", "runtime_status"]

      assert rows(index, "SELECT operation_id FROM operations_fts ORDER BY operation_id") == [
               ["runtime_start"],
               ["runtime_status"]
             ]

      assert [%{sources: [%{version: "2.0.0", operations: 2}]}] = Tama.Dex.cassettes(index)
    end

    test "a duplicate operation within a cassette fails, naming the ID and owner", %{index: index} do
      {:ok, _loaded} =
        Tama.Dex.load(index, document("macus", ["runtime_start", "runtime_stop"]),
          cassette: "macus"
        )

      before = rows(index, "SELECT * FROM operations ORDER BY id")

      assert {:error,
              {:duplicate_operation, [%{source: "macus", operation_ids: ["runtime_stop"]}]}} =
               Tama.Dex.load(index, document("plugin", ["plugin_run", "runtime_stop"]),
                 cassette: "macus"
               )

      assert rows(index, "SELECT * FROM operations ORDER BY id") == before
      assert [%{sources: [%{source: "macus"}]}] = Tama.Dex.cassettes(index)

      assert {:ok, _loaded} =
               Tama.Dex.load(index, document("plugin", ["plugin_run", "runtime_stop"]),
                 cassette: "plugins"
               )
    end

    test "reloading the same document changes nothing", %{index: index} do
      doc = document("macus", ["runtime_start"])
      {:ok, %{changed: true}} = Tama.Dex.load(index, doc, cassette: "macus")
      before = {rows(index, "SELECT * FROM sources"), rows(index, "SELECT * FROM operations")}

      assert {:ok, %{changed: false, operations: 1, source: "macus", cassette: "macus"}} =
               Tama.Dex.load(index, doc, cassette: "macus")

      assert {rows(index, "SELECT * FROM sources"), rows(index, "SELECT * FROM operations")} ==
               before
    end

    test "a failed load leaves the source's entries in place", %{index: index} do
      {:ok, _loaded} =
        Tama.Dex.load(index, document("macus", ["runtime_start"]), cassette: "macus")

      before = rows(index, "SELECT * FROM operations")

      invalid = Map.put(document("macus", ["runtime_stop"]), "x-tama-source", "Macus")

      assert {:error, {:invalid_document, [%{code: :invalid_field}]}} =
               Tama.Dex.load(index, invalid, cassette: "macus")

      assert rows(index, "SELECT * FROM operations") == before
    end

    test "documents are validated under the index's limits" do
      index = start_index!(path: :memory, limits: [max_operations: 2])

      assert {:error, {:invalid_document, [%{code: :too_many_operations}]}} =
               Tama.Dex.load(index, document("alpha", ["a_one", "a_two", "a_three"]),
                 cassette: "alpha"
               )

      assert {:ok, _loaded} =
               Tama.Dex.load(index, document("alpha", ["a_one", "a_two"]), cassette: "alpha")
    end

    test "stored rows are derived from the normalized document", %{index: index} do
      {:ok, _loaded} =
        Tama.Dex.load(index, fixture("profile/valid/opsmaru_incus.json"),
          cassette: "opsmaru_incus"
        )

      [[tags, scopes, destructive, confirmation, bounds, identity, extensions, error_digest]] =
        rows(index, """
        SELECT tags, scopes, destructive, confirmation, bounds, identity, extensions, error_schema_digest
        FROM operations WHERE operation_id = 'incus_image_delete'
        """)

      assert tags == ~s(["image"])
      assert scopes == ~s(["incus.delete"])
      assert destructive == 1
      assert confirmation == ~s({"description":"the full fingerprint","field":"confirm"})
      assert bounds == ~s({"max_wait_seconds":60})
      assert identity == ~s(["operation_id","status"])
      assert extensions == ~s({"x-opsmaru-requires":["DeleteImage","GetOperationWait"]})
      assert error_digest =~ ~r/^[0-9a-f]{64}$/

      assert [[nil, nil]] =
               rows(
                 index,
                 "SELECT confirmation, identity FROM operations WHERE operation_id = 'incus_instance_list'"
               )

      assert [["incus_image_delete"]] =
               rows(
                 index,
                 "SELECT operation_id FROM operations_fts WHERE operations_fts MATCH 'fingerprint' AND tags MATCH 'image'"
               )
    end
  end

  describe "concurrent readers" do
    @tag timeout: 60_000
    test "never see a mixture during a reload of a file-backed index", %{tmp_dir: tmp_dir} do
      assert_no_mixture(start_index!(path: Path.join(tmp_dir, "index.sqlite3")))
    end

    @tag timeout: 60_000
    test "never see a mixture during a reload of an in-memory index" do
      assert_no_mixture(start_index!(path: :memory))
    end

    defp assert_no_mixture(index) do
      old_ids = Enum.map(1..60, &"old_#{&1}")
      new_ids = Enum.map(1..60, &"new_#{&1}")
      old = document("macus", old_ids)
      new = document("macus", new_ids, version: "2.0.0")

      {:ok, _loaded} = Tama.Dex.load(index, old, cassette: "macus")

      read = fn ->
        Index.read(index, fn conn ->
          SQL.execute!(conn, "BEGIN")

          ids =
            conn
            |> SQL.query!(
              "SELECT operation_id FROM operations WHERE cassette = 'macus' ORDER BY operation_id"
            )
            |> List.flatten()

          [[fts]] = SQL.query!(conn, "SELECT count(*) FROM operations_fts")
          SQL.execute!(conn, "COMMIT")
          {ids, fts}
        end)
      end

      readers =
        for _reader <- 1..4 do
          Task.async(fn ->
            Stream.repeatedly(read) |> Enum.take(150)
          end)
        end

      for doc <- [new, old, new, old, new] do
        {:ok, %{changed: true}} = Tama.Dex.load(index, doc, cassette: "macus")
      end

      seen = readers |> Enum.flat_map(&Task.await(&1, 50_000)) |> Enum.uniq()

      for {ids, fts} <- seen do
        assert ids in [Enum.sort(old_ids), Enum.sort(new_ids)], "mixed view: #{inspect(ids)}"
        assert fts == 60
      end
    end
  end

  describe "persistence and schema versions" do
    test "a restart on the same file keeps cassettes and compiles nothing", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "index.sqlite3")
      first = start_index!(path: path)
      {:ok, _loaded} = Tama.Dex.load(first, document("alpha", ["a_one"]), cassette: "alpha")
      before = Tama.Dex.cassettes(first)
      :ok = GenServer.stop(first)

      ref = :telemetry_test.attach_event_handlers(self(), [[:tama_dex, :index, :recreated]])
      second = start_index!(path: path)

      assert Tama.Dex.cassettes(second) == before
      assert :ets.info(Index.schema_cache(second), :size) == 0
      refute_received {[:tama_dex, :index, :recreated], ^ref, _measurements, _metadata}
    end

    test "a development version 1 index is recreated before any write", %{tmp_dir: tmp_dir} do
      # Version 1 had a required operations.token_count column, which loads
      # no longer fill.
      path = Path.join(tmp_dir, "v1.sqlite3")
      {:ok, conn} = Sqlite3.open(path)

      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO meta VALUES ('schema_version', '1');
        CREATE TABLE operations (id INTEGER PRIMARY KEY, token_count INTEGER NOT NULL);
        """)

      :ok = Sqlite3.close(conn)

      index = start_supervised!({Index, path: path})

      assert {:ok, %{changed: true}} =
               Tama.Dex.load(index, document("acme", ["one"]), cassette: "acme")

      assert rows(index, "SELECT value FROM meta WHERE key = 'schema_version'") == [["2"]]
    end

    test "an older schema version is recreated empty", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "old.sqlite3")
      {:ok, conn} = Sqlite3.open(path)

      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO meta VALUES ('schema_version', '0');
        CREATE TABLE cassettes (cassette TEXT PRIMARY KEY);
        INSERT INTO cassettes VALUES ('stale');
        CREATE VIEW stale_view AS SELECT * FROM cassettes;
        CREATE TRIGGER stale_trigger AFTER INSERT ON meta BEGIN SELECT 1; END;
        CREATE VIRTUAL TABLE stale_fts USING fts5(text);
        """)

      :ok = Sqlite3.close(conn)

      ref = :telemetry_test.attach_event_handlers(self(), [[:tama_dex, :index, :recreated]])
      index = start_index!(path: path)

      assert_received {[:tama_dex, :index, :recreated], ^ref, %{}, %{old_version: 0, version: 2}}
      assert Tama.Dex.cassettes(index) == []

      names =
        rows(index, "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")

      refute ["stale_view"] in names
      refute ["stale_trigger"] in names
      refute ["stale_fts"] in names

      assert {:ok, _loaded} =
               Tama.Dex.load(index, document("alpha", ["a_one"]), cassette: "alpha")
    end

    test "a database with tables but no schema version is recreated", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "foreign.sqlite3")
      {:ok, conn} = Sqlite3.open(path)
      :ok = Sqlite3.execute(conn, "CREATE TABLE things (id INTEGER)")
      :ok = Sqlite3.close(conn)

      ref = :telemetry_test.attach_event_handlers(self(), [[:tama_dex, :index, :recreated]])
      index = start_index!(path: path)

      assert_received {[:tama_dex, :index, :recreated], ^ref, %{}, %{old_version: nil}}
      refute ["things"] in rows(index, "SELECT name FROM sqlite_master")
    end

    test "a meta table without a version is recreated", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "meta.sqlite3")
      {:ok, conn} = Sqlite3.open(path)
      :ok = Sqlite3.execute(conn, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      :ok = Sqlite3.close(conn)

      ref = :telemetry_test.attach_event_handlers(self(), [[:tama_dex, :index, :recreated]])
      _index = start_index!(path: path)

      assert_received {[:tama_dex, :index, :recreated], ^ref, %{}, %{old_version: nil}}
    end
  end

  describe "compiled schema cache" do
    test "schemas compile on first use and unreferenced entries are dropped" do
      index = start_index!(path: :memory)
      cache = Index.schema_cache(index)

      {:ok, _loaded} = Tama.Dex.load(index, document("alpha", ["a_one"]), cassette: "alpha")
      assert :ets.info(cache, :size) == 0

      [[digest, text]] = rows(index, "SELECT input_schema_digest, input_schema FROM operations")
      assert {:ok, compiled} = Index.compiled_schema(cache, digest, text)
      assert {:ok, ^compiled} = Index.compiled_schema(cache, digest, text)
      assert :ets.info(cache, :size) == 1

      # An unchanged reload keeps it; a change that drops the schema drops it.
      {:ok, %{changed: false}} =
        Tama.Dex.load(index, document("alpha", ["a_one"]), cassette: "alpha")

      assert :ets.lookup(cache, digest) != []

      {:ok, %{changed: true}} =
        Tama.Dex.load(index, document("alpha", ["a_one"], property: "label"), cassette: "alpha")

      assert :ets.lookup(cache, digest) == []

      [[digest, text]] = rows(index, "SELECT input_schema_digest, input_schema FROM operations")
      {:ok, _compiled} = Index.compiled_schema(cache, digest, text)
      :ok = Tama.Dex.unload(index, "alpha")
      assert :ets.info(cache, :size) == 0
    end

    test "a schema shared by several operations is cached once" do
      index = start_index!(path: :memory)

      {:ok, _loaded} =
        Tama.Dex.load(index, document("alpha", ["a_one", "a_two"]), cassette: "alpha")

      assert [[2, 1]] =
               rows(index, "SELECT count(*), count(DISTINCT input_schema_digest) FROM operations")
    end
  end

  describe "telemetry" do
    test "load emits start and stop events with bounded metadata" do
      index = start_index!(path: :memory)

      ref =
        attach_local([
          [:tama_dex, :load, :start],
          [:tama_dex, :load, :stop]
        ])

      {:ok, _loaded} = Tama.Dex.load(index, document("alpha", ["a_one"]), cassette: "alpha")

      assert_received {[:tama_dex, :load, :start], ^ref, %{system_time: _}, %{cassette: "alpha"}}

      assert_received {[:tama_dex, :load, :stop], ^ref, %{duration: _},
                       %{
                         cassette: "alpha",
                         source: "alpha",
                         changed: true,
                         operations: 1,
                         result: :ok
                       }}

      {:error, _reason} = Tama.Dex.load(index, %{}, cassette: "alpha")

      assert_received {[:tama_dex, :load, :stop], ^ref, _measurements,
                       %{cassette: "alpha", result: :invalid_document} = metadata}

      refute Map.has_key?(metadata, :issues)
    end
  end
end
