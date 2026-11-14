defmodule Tama.Dex.ImportTest do
  use ExUnit.Case, async: true

  import Tama.Dex.TestSupport.Cassettes
  import Tama.Dex.TestSupport.Documents

  alias Tama.Dex.Index
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.TestSupport.CountingExecutor

  @moduletag :tmp_dir

  @scopes ["incus.read", "incus.write", "incus.exec", "incus.delete", "test.read"]

  defp start_index!, do: start_supervised!({Index, path: :memory}, id: make_ref())

  defp ids(index, cassette) do
    index
    |> Index.read(
      &SQL.query!(
        &1,
        "SELECT operation_id FROM operations WHERE cassette = ? ORDER BY operation_id",
        [
          cassette
        ]
      )
    )
    |> List.flatten()
  end

  defp search_ids(index, query, opts \\ []) do
    {:ok, %{results: results}} =
      Tama.Dex.search(index, query, Keyword.merge([scopes: @scopes, limit: 20], opts))

    Enum.map(results, &{&1.cassette, &1.operation_id})
  end

  defp describe_all(index, cassette) do
    for id <- ids(index, cassette) do
      {:ok, described} = Tama.Dex.describe(index, cassette, id, scopes: @scopes)
      described
    end
  end

  defp cassette(index, name), do: Enum.find(Tama.Dex.cassettes(index), &(&1.cassette == name))

  describe "a pinned release cassette" do
    test "installs every source in copy mode, searchable at once", %{tmp_dir: dir} do
      index = start_index!()
      built = incus!(dir, "0.2.0")

      assert {:ok, result} = Tama.Dex.import(index, built.path, sha256: built.sha256)

      assert result == %{
               cassette: "opsmaru_incus",
               version: "0.2.0",
               digest: built.digest,
               mode: :copy,
               changed: true,
               sources: [
                 %{source: "opsmaru_incus", operations: 4},
                 %{source: "opsmaru_native", operations: 1}
               ]
             }

      assert [{"opsmaru_incus", "incus_image_delete"}] = search_ids(index, "image delete")
      assert [{"opsmaru_incus", "native_status"}] = search_ids(index, "native_status")

      assert %{kind: :imported, status: :ready, mode: :copy, version: "0.2.0"} =
               cassette(index, "opsmaru_incus")
    end

    test "gives the same entries as a rebuild", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")
      copied = start_index!()
      rebuilt = start_index!()

      {:ok, %{mode: :copy}} = Tama.Dex.import(copied, built.path, sha256: built.sha256)
      {:ok, %{mode: :rebuild}} = Tama.Dex.import(rebuilt, built.path)

      assert describe_all(copied, "opsmaru_incus") == describe_all(rebuilt, "opsmaru_incus")

      for query <- [nil, "instance", "fingerprint", "image delete", "native"] do
        assert search_ids(copied, query) == search_ids(rebuilt, query)
      end
    end

    test "copied rows get their own IDs, so one cassette can be installed twice",
         %{tmp_dir: dir} do
      index = start_index!()
      built = incus!(dir, "0.2.0")

      {:ok, %{mode: :copy}} = Tama.Dex.import(index, built.path, sha256: built.sha256)

      {:ok, %{mode: :copy, cassette: "mirror"}} =
        Tama.Dex.import(index, built.path, sha256: built.sha256, as: "mirror")

      assert search_ids(index, "image delete") ==
               [{"mirror", "incus_image_delete"}, {"opsmaru_incus", "incus_image_delete"}]

      assert Index.read(index, &SQL.query!(&1, "SELECT count(*) FROM operations_fts")) == [[10]]
    end

    test "can be executed", %{tmp_dir: dir} do
      index = start_index!()
      built = incus!(dir, "0.2.0")
      {:ok, _result} = Tama.Dex.import(index, built.path, sha256: built.sha256)

      executors = %{
        "opsmaru_incus" =>
          {CountingExecutor,
           test: self(), respond: fn _call, _input -> {:ok, %{"instances" => []}} end}
      }

      assert {:ok, %{result: %{"instances" => []}}} =
               Tama.Dex.execute(index, "opsmaru_incus", "incus_instance_list", %{},
                 scopes: ["incus.read"],
                 executors: executors
               )
    end
  end

  test "several cassettes live side by side in one index", %{tmp_dir: dir} do
    index = start_index!()
    incus = incus!(dir, "0.2.0")

    macus =
      build!(dir, "macus.tama-cassette", [document("macus", ["list_instances"])],
        name: "macus",
        version: "1.0.0"
      )

    {:ok, _result} = Tama.Dex.import(index, incus.path, sha256: incus.sha256)
    before = cassette(index, "opsmaru_incus")
    {:ok, %{cassette: "macus", mode: :rebuild}} = Tama.Dex.import(index, macus.path)

    assert search_ids(index, "instance list") ==
             [{"macus", "list_instances"}, {"opsmaru_incus", "incus_instance_list"}]

    assert cassette(index, "opsmaru_incus") == before
    assert Enum.map(Tama.Dex.cassettes(index), & &1.cassette) == ["macus", "opsmaru_incus"]
  end

  describe "an upgrade" do
    for pinned <- [true, false] do
      test "drops operations the new version lacks (pinned: #{pinned})", %{tmp_dir: dir} do
        index = start_index!()

        {:ok, _loaded} =
          Tama.Dex.load(index, document("macus", ["list_instances"]), cassette: "macus")

        macus = cassette(index, "macus")

        old = incus!(dir, "0.2.0")
        new = incus!(dir, "0.3.0", drop: "incus_image_delete", native: ["native_health"])
        pin = fn built -> if unquote(pinned), do: [sha256: built.sha256], else: [] end

        {:ok, _result} = Tama.Dex.import(index, old.path, pin.(old))

        assert {:ok, %{version: "0.3.0", changed: true}} =
                 Tama.Dex.import(index, new.path, pin.(new))

        assert ids(index, "opsmaru_incus") ==
                 [
                   "incus_instance_create",
                   "incus_instance_exec",
                   "incus_instance_list",
                   "native_health"
                 ]

        assert search_ids(index, "image delete") == []
        assert search_ids(index, "native status") == []
        assert cassette(index, "macus") == macus
        assert cassette(index, "opsmaru_incus").version == "0.3.0"
      end
    end
  end

  test "as: installs a colliding cassette under another name", %{tmp_dir: dir} do
    index = start_index!()

    ours =
      build!(dir, "ours.tama-cassette", [document("macus", ["list_instances"])],
        name: "macus",
        version: "1.0.0"
      )

    theirs =
      build!(dir, "theirs.tama-cassette", [document("acme", ["acme_widget_get"])],
        name: "macus",
        version: "9.9.9"
      )

    {:ok, _result} = Tama.Dex.import(index, ours.path)
    before = cassette(index, "macus")

    assert {:ok, %{cassette: "acme", version: "9.9.9"}} =
             Tama.Dex.import(index, theirs.path, as: "acme")

    assert cassette(index, "macus") == before
    assert ids(index, "acme") == ["acme_widget_get"]
    assert ids(index, "macus") == ["list_instances"]
  end

  describe "an untrusted cassette" do
    test "with tampered rows and no pin is rebuilt from its documents", %{tmp_dir: dir} do
      index = start_index!()
      built = incus!(dir, "0.2.0")

      tamper!(built.path, [
        {"UPDATE operations SET scopes = ?, destructive = 0 WHERE operation_id = ?",
         [~s(["test.read"]), "incus_image_delete"]}
      ])

      assert {:ok, %{mode: :rebuild}} = Tama.Dex.import(index, built.path)

      assert {:error, :not_found} =
               Tama.Dex.describe(index, "opsmaru_incus", "incus_image_delete",
                 scopes: ["test.read"]
               )

      assert {:ok, %{scopes: ["incus.delete"], destructive: true}} =
               Tama.Dex.describe(index, "opsmaru_incus", "incus_image_delete",
                 scopes: ["incus.delete"]
               )
    end

    test "with a wrong pin is rejected, changing nothing", %{tmp_dir: dir} do
      index = start_index!()
      built = incus!(dir, "0.2.0")

      assert Tama.Dex.import(index, built.path, sha256: String.duplicate("0", 64)) ==
               {:error, :sha256_mismatch}

      assert Tama.Dex.cassettes(index) == []
      assert Index.status(index) == :empty
    end

    test "with an altered document is rejected, changing nothing", %{tmp_dir: dir} do
      index = start_index!()
      old = incus!(dir, "0.2.0")
      {:ok, _result} = Tama.Dex.import(index, old.path)
      before = describe_all(index, "opsmaru_incus")

      new = incus!(dir, "0.3.0")

      tamper!(new.path, [
        {"UPDATE cassette_documents SET document = replace(document, 'incus.delete', 'incus.read') WHERE source = ?",
         ["opsmaru_incus"]}
      ])

      assert Tama.Dex.import(index, new.path) ==
               {:error, {:document_digest_mismatch, "opsmaru_incus"}}

      assert describe_all(index, "opsmaru_incus") == before
      assert cassette(index, "opsmaru_incus").version == "0.2.0"
    end
  end

  test "an older index schema is imported in rebuild mode, even when pinned", %{tmp_dir: dir} do
    index = start_index!()
    built = incus!(dir, "0.2.0")

    path =
      built.path
      |> tamper!(["DROP TABLE operations_fts", "CREATE TABLE legacy_search (operation_id TEXT)"])
      |> set_schema_version!(0)

    assert {:ok, %{mode: :rebuild, changed: true}} =
             Tama.Dex.import(index, path, sha256: sha256!(path))

    assert [{"opsmaru_incus", "incus_image_delete"}] = search_ids(index, "image delete")
  end

  test "importing the same content again writes nothing", %{tmp_dir: dir} do
    index = start_index!()
    built = incus!(dir, "0.2.0")

    {:ok, %{changed: true}} = Tama.Dex.import(index, built.path, sha256: built.sha256)
    before = cassette(index, "opsmaru_incus")

    assert {:ok, %{changed: false, mode: :copy}} = Tama.Dex.import(index, built.path)
    assert cassette(index, "opsmaru_incus") == before
  end

  test "a name held by a local cassette is a conflict", %{tmp_dir: dir} do
    index = start_index!()

    {:ok, _loaded} =
      Tama.Dex.load(index, document("macus", ["list_instances"]), cassette: "macus")

    built =
      build!(dir, "macus.tama-cassette", [document("macus", ["other_op"])],
        name: "macus",
        version: "1"
      )

    assert Tama.Dex.import(index, built.path) == {:error, :cassette_conflict}
    assert ids(index, "macus") == ["list_instances"]

    {:ok, _result} = Tama.Dex.import(index, built.path, as: "remote")

    assert Tama.Dex.load(index, document("remote", ["x_op"]), cassette: "remote") ==
             {:error, :cassette_conflict}
  end

  test "checks its options", %{tmp_dir: dir} do
    index = start_index!()
    built = incus!(dir, "0.2.0")

    assert_raise ArgumentError, fn -> Tama.Dex.import(index, built.path, sha256: "nope") end
    assert_raise ArgumentError, fn -> Tama.Dex.import(index, built.path, as: "Bad") end
    assert_raise ArgumentError, fn -> Tama.Dex.import(index, built.path, timeout: 0) end
    assert_raise ArgumentError, fn -> Tama.Dex.import(index, built.path, async: "yes") end
    assert_raise ArgumentError, fn -> Tama.Dex.import(index, nil) end
    assert Tama.Dex.import(index, Path.join(dir, "missing")) == {:error, {:file, :enoent}}
  end

  test "emits an import span without the path", %{tmp_dir: dir} do
    index = start_index!()
    built = incus!(dir, "0.2.0")

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:tama_dex, :import, :start],
        [:tama_dex, :import, :stop]
      ])

    {:ok, _result} =
      Tama.Dex.import(index, built.path, sha256: built.sha256, as: "telemetry_probe")

    assert_receive {[:tama_dex, :import, :start], ^ref, _measurements,
                    %{cassette: "telemetry_probe"}}

    # The import runs in the index's writer, so match this test's cassette.
    assert_receive {[:tama_dex, :import, :stop], ^ref, %{duration: _duration},
                    %{cassette: "telemetry_probe"} = metadata}

    :telemetry.detach(ref)

    assert Map.delete(metadata, :telemetry_span_context) == %{
             cassette: "telemetry_probe",
             version: "0.2.0",
             mode: :copy,
             changed: true,
             sources: 2,
             operations: 5,
             result: :ok
           }

    refute inspect(metadata) =~ dir
  end
end
