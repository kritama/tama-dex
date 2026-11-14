defmodule Tama.Dex.ReadinessTest do
  use ExUnit.Case, async: true

  import Tama.Dex.TestSupport.Cassettes
  import Tama.Dex.TestSupport.Documents

  alias Tama.Dex.Error
  alias Tama.Dex.Index
  alias Tama.Dex.Index.Job
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.Index.Store
  alias Tama.Dex.MCP
  alias Tama.Dex.Profile
  alias Tama.Dex.TestSupport.CountingExecutor

  @moduletag :tmp_dir

  @scopes ["incus.read", "incus.write", "incus.exec", "incus.delete", "test.read"]

  defp start_index!(path \\ :memory), do: start_supervised!({Index, path: path}, id: make_ref())

  defp macus!(dir, ids \\ ["list_instances"]) do
    build!(dir, "macus.tama-cassette", [document("macus", ids)], name: "macus", version: "1.0.0")
  end

  defp search(index, query \\ nil, opts \\ []) do
    Tama.Dex.search(index, query, Keyword.merge([scopes: @scopes, limit: 20], opts))
  end

  defp execute(index, cassette, id) do
    Tama.Dex.execute(index, cassette, id, %{},
      scopes: @scopes,
      executors: %{"macus" => {CountingExecutor, test: self()}}
    )
  end

  defp count(index, cassette) do
    [[count]] =
      Index.read(
        index,
        &SQL.query!(&1, "SELECT count(*) FROM operations WHERE cassette = ?", [cassette])
      )

    count
  end

  defp cassette(index, name), do: Enum.find(Tama.Dex.cassettes(index), &(&1.cassette == name))

  defp count_in(conn, cassette) do
    [[count]] = SQL.query!(conn, "SELECT count(*) FROM operations WHERE cassette = ?", [cassette])
    count
  end

  describe "status/1" do
    test "is empty, then ready once a cassette commits" do
      index = start_index!()
      ref = :telemetry_test.attach_event_handlers(self(), [[:tama_dex, :index, :status]])

      assert Index.status(index) == :empty
      assert {:ok, %{results: []}} = search(index)

      {:ok, _loaded} =
        Tama.Dex.load(index, document("macus", ["list_instances"]), cassette: "macus")

      assert Index.status(index) == :ready

      statuses = collect_statuses(ref, index)
      :telemetry.detach(ref)

      assert List.first(statuses) == {:importing, %{cassette: "macus", done: 0, total: 0}}
      assert List.last(statuses) == :ready
    end

    test "starts ready for an index file that already holds cassettes", %{tmp_dir: dir} do
      path = Path.join(dir, "index.sqlite3")
      index = start_supervised!({Index, path: path}, id: :first)

      {:ok, _loaded} =
        Tama.Dex.load(index, document("macus", ["list_instances"]), cassette: "macus")

      :ok = stop_supervised(:first)

      assert Index.status(start_index!(path)) == :ready
    end

    test "reports the last failure while nothing is committed", %{tmp_dir: dir} do
      index = start_index!()
      built = macus!(dir)
      tamper!(built.path, "UPDATE cassette_documents SET document = document || ' '")

      assert {:error, {:document_digest_mismatch, "macus"}} = Tama.Dex.import(index, built.path)
      assert Index.status(index) == {:failed, :document_digest_mismatch}

      assert [%{cassette: "macus", status: {:failed, :document_digest_mismatch}, sources: []}] =
               Tama.Dex.cassettes(index)

      # A failure isn't in progress, so reads answer from what is committed.
      assert {:ok, %{results: []}} = search(index)

      :ok = Tama.Dex.unload(index, "macus")
      assert Tama.Dex.cassettes(index) == []
    end
  end

  defp collect_statuses(ref, index) do
    receive do
      {[:tama_dex, :index, :status], ^ref, _measurements, %{index: ^index, status: status}} ->
        [status | collect_statuses(ref, index)]

      {[:tama_dex, :index, :status], ^ref, _measurements, _other} ->
        collect_statuses(ref, index)
    after
      100 -> []
    end
  end

  describe "deadlines" do
    test "an import over its timeout keeps the previous cassettes", %{tmp_dir: dir} do
      index = start_index!()

      {:ok, _loaded} =
        Tama.Dex.load(index, document("macus", ["list_instances"]), cassette: "macus")

      before = Tama.Dex.cassettes(index)
      bulk = bulk!(dir, "fleet", 800)

      assert Tama.Dex.import(index, bulk.path, timeout: 1) == {:error, :deadline}

      # A deadline reached in the writer lists the uncommitted cassette as
      # failed; one reached before queueing doesn't list it.
      {failed, committed} = Enum.split_with(Tama.Dex.cassettes(index), &(&1.cassette == "fleet"))
      assert committed == before
      assert failed == [] or match?([%{status: {:failed, :deadline}}], failed)
      assert Index.status(index) == :ready
    end

    test "a deadline passing mid-transaction rolls the write back" do
      index = start_index!()

      {:ok, _loaded} =
        Tama.Dex.load(index, document("macus", ["list_instances"]), cassette: "macus")

      before = Tama.Dex.cassettes(index)

      {:ok, upgrade} =
        Profile.validate(document("macus", ["list_instances", "runtime_start"]))

      test = self()

      # Store.load deletes the source's rows, then reaches its first
      # checkpoint with the deadline already passed.
      result =
        Index.run(
          index,
          fn conn, job ->
            Job.guard(fn ->
              SQL.transaction(conn, fn ->
                Store.write_source(conn, "macus", upgrade, Store.now(), nil)
                send(test, {:written, count_in(conn, "macus")})
                Job.checkpoint(job)
                {:commit, {:changed, :ok}}
              end)
            end)
          end,
          cassette: "macus",
          kind: :local,
          deadline: System.monotonic_time(:millisecond) - 1
        )

      assert result == {:error, :deadline}
      assert_received {:written, 2}
      assert Tama.Dex.cassettes(index) == before
      assert count(index, "macus") == 1
    end

    test "a write still waiting when its deadline passes is rolled back", %{tmp_dir: dir} do
      index = start_index!()
      {:ok, _result} = Tama.Dex.import(index, macus!(dir).path)
      before = Tama.Dex.cassettes(index)
      writer = hold_writer!(index)

      upgrade = macus!(dir, ["list_instances", "runtime_start"])
      importing = Task.async(fn -> Tama.Dex.import(index, upgrade.path, timeout: 20) end)

      loading =
        Task.async(fn ->
          Tama.Dex.load(index, document("local", ["local_op"]), cassette: "local", timeout: 20)
        end)

      Process.sleep(50)
      release(writer)

      assert Task.await(importing) == {:error, :deadline}
      assert Task.await(loading) == {:error, :deadline}

      # The local cassette never committed, so it is listed as failed.
      assert [%{cassette: "local", status: {:failed, :deadline}} | committed] =
               Tama.Dex.cassettes(index)

      assert committed == before
      assert count(index, "macus") == 1
    end

    test "a load whose deadline passes during validation writes nothing" do
      index = start_index!()

      ids = Enum.map(1..400, &"bulk_op_#{&1}")

      assert Tama.Dex.load(index, document("bulk", ids), cassette: "bulk", timeout: 1) ==
               {:error, :deadline}

      assert Tama.Dex.cassettes(index) == []
    end

    test "without a timeout, a call waits past GenServer's default", %{tmp_dir: dir} do
      index = start_index!()
      writer = hold_writer!(index)
      importing = Task.async(fn -> Tama.Dex.import(index, macus!(dir).path) end)

      Process.sleep(5_100)
      release(writer)

      assert {:ok, %{cassette: "macus"}} = Task.await(importing, 10_000)
    end

    test "checks the timeout option" do
      index = start_index!()

      assert {:ok, _loaded} =
               Tama.Dex.load(index, document("macus", ["list_instances"]),
                 cassette: "macus",
                 timeout: :infinity
               )

      for timeout <- [0, -1, 1.5, "1000"] do
        assert_raise ArgumentError, fn ->
          Tama.Dex.load(index, document("macus", ["list_instances"]),
            cassette: "macus",
            timeout: timeout
          )
        end
      end
    end
  end

  describe "a background import" do
    test "returns at once, and reads are not_ready until it commits", %{tmp_dir: dir} do
      index = start_index!()
      writer = hold_writer!(index)
      built = incus!(dir, "0.2.0")

      assert {:ok, ref} = Tama.Dex.import(index, built.path, sha256: built.sha256, async: true)

      assert Index.status(index) == {:importing, %{cassette: "opsmaru_incus", done: 0, total: 0}}
      assert search(index) == {:error, :not_ready}

      assert Tama.Dex.describe(index, "opsmaru_incus", "incus_instance_list", scopes: @scopes) ==
               {:error, :not_ready}

      assert {:error, %Error{kind: :not_ready, dispatched: false}} =
               execute(index, "opsmaru_incus", "incus_instance_list")

      caller = %{scopes: @scopes}

      assert %{"error" => %{"kind" => "not_ready", "dispatched" => false}} =
               MCP.handle_search(index, %{}, caller)

      assert %{"error" => %{"kind" => "not_ready", "dispatched" => false}} =
               MCP.handle_execute(
                 index,
                 %{
                   "cassette" => "opsmaru_incus",
                   "operation_id" => "incus_instance_list",
                   "input" => %{}
                 },
                 caller,
                 %{}
               )

      release(writer)

      assert_receive {:tama_dex_import, ^ref, {:ok, %{mode: :copy, changed: true}}}, 5_000
      assert Index.status(index) == :ready
      assert {:ok, %{results: [_ | _]}} = search(index)
      refute_received {:executed, _call, _input}
    end

    test "sends what a synchronous import returns", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")

      assert {:ok, ref} =
               Tama.Dex.import(start_index!(), built.path, sha256: built.sha256, async: true)

      assert_receive {:tama_dex_import, ^ref, result}, 5_000

      assert result == Tama.Dex.import(start_index!(), built.path, sha256: built.sha256)

      index = start_index!()
      writer = hold_writer!(index)
      assert {:ok, ref} = Tama.Dex.import(index, built.path, timeout: 20, async: true)
      Process.sleep(50)
      release(writer)
      assert_receive {:tama_dex_import, ^ref, {:error, :deadline}}, 5_000
    end

    test "fails at once when the file fails its first checks", %{tmp_dir: dir} do
      index = start_index!()
      built = incus!(dir, "0.2.0")

      assert Tama.Dex.import(index, built.path, sha256: String.duplicate("0", 64), async: true) ==
               {:error, :sha256_mismatch}

      trigger = tamper!(incus!(dir, "0.2.1").path, "CREATE VIEW v AS SELECT 1")
      assert Tama.Dex.import(index, trigger, async: true) == {:error, {:unexpected_schema, ["v"]}}

      assert Index.status(index) == :empty
    end

    test "of a second cassette leaves the first one serving", %{tmp_dir: dir} do
      index = start_index!()
      incus = incus!(dir, "0.2.0")
      {:ok, _result} = Tama.Dex.import(index, incus.path, sha256: incus.sha256)

      writer = hold_writer!(index)
      {:ok, ref} = Tama.Dex.import(index, macus!(dir).path, async: true)

      assert Index.status(index) == :ready
      assert {:ok, %{results: results}} = search(index, "instance")
      assert Enum.all?(results, &(&1.cassette == "opsmaru_incus"))

      assert %{status: {:importing, %{cassette: "macus"}}, kind: :imported, sources: []} =
               cassette(index, "macus")

      assert %{status: :ready} = cassette(index, "opsmaru_incus")
      assert {:error, %Error{kind: :not_ready}} = execute(index, "macus", "list_instances")

      assert Tama.Dex.describe(index, "macus", "list_instances", scopes: @scopes) ==
               {:error, :not_ready}

      assert {:ok, _described} =
               Tama.Dex.describe(index, "opsmaru_incus", "incus_instance_list", scopes: @scopes)

      release(writer)
      assert_receive {:tama_dex_import, ^ref, {:ok, %{cassette: "macus"}}}, 5_000

      assert %{status: :ready} = cassette(index, "macus")
      assert {:ok, %{result: %{}}} = execute(index, "macus", "list_instances")
    end

    test "that fails leaves the index ready and reports the failure", %{tmp_dir: dir} do
      index = start_index!()
      incus = incus!(dir, "0.2.0")
      {:ok, _result} = Tama.Dex.import(index, incus.path)

      macus = macus!(dir)
      tamper!(macus.path, "UPDATE cassette_documents SET document = document || ' '")

      {:ok, ref} = Tama.Dex.import(index, macus.path, async: true)

      assert_receive {:tama_dex_import, ^ref, {:error, {:document_digest_mismatch, "macus"}}},
                     5_000

      assert Index.status(index) == :ready
      assert %{status: {:failed, :document_digest_mismatch}} = cassette(index, "macus")
      assert %{status: :ready} = cassette(index, "opsmaru_incus")
    end
  end

  describe "a re-import" do
    for kind <- [:file, :memory] do
      test "serves the previous entries or the new ones, never a mixture (#{kind})",
           %{tmp_dir: dir} do
        index =
          case unquote(kind) do
            :file -> start_index!(Path.join(dir, "index.sqlite3"))
            :memory -> start_index!()
          end

        {:ok, _result} = Tama.Dex.import(index, bulk!(dir, "fleet", 50, "1").path)
        upgrade = bulk!(dir, "fleet", 600, "2")

        {:ok, ref} = Tama.Dex.import(index, upgrade.path, async: true)
        counts = observe(index, ref)

        assert Enum.all?(counts, &(&1 in [50, 600])), inspect(Enum.uniq(counts))
        assert count(index, "fleet") == 600

        if unquote(kind) == :file do
          # A file-backed index keeps serving the previous entries while the
          # import verifies and writes the new ones.
          assert List.first(counts) == 50
        end
      end
    end
  end

  # Reads the cassette's operation count and searches it until the import's
  # result arrives.
  defp observe(index, ref) do
    count = count(index, "fleet")
    assert {:ok, %{results: [_ | _]}} = search(index, "fleet op 0001", cassette: "fleet")
    assert %{status: :ready} = cassette(index, "fleet")

    receive do
      {:tama_dex_import, ^ref, {:ok, %{changed: true}}} -> [count]
    after
      0 -> [count | observe(index, ref)]
    end
  end
end
