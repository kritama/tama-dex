defmodule Tama.Dex.SearchTest do
  use ExUnit.Case, async: true

  import Tama.Dex.TestSupport.Documents

  alias Tama.Dex.Index
  alias Tama.Dex.Search

  @incus_scopes ["incus.read", "incus.write", "incus.exec", "incus.delete"]
  @all_scopes @incus_scopes ++ ["test.read"]
  @op_path ["paths", "/operations/incus_image_delete", "post"]

  defp start_index!, do: start_supervised!({Index, path: :memory}, id: make_ref())

  defp load!(index, document, cassette) do
    {:ok, _loaded} = Tama.Dex.load(index, document, cassette: cassette)
    index
  end

  defp incus!(index),
    do: load!(index, fixture("profile/valid/opsmaru_incus.json"), "opsmaru_incus")

  defp macus!(index) do
    load!(
      index,
      document("macus", ["list_instances", "instance_start", "runtime_status"]),
      "macus"
    )
  end

  defp search!(index, query, opts) do
    {:ok, response} = Tama.Dex.search(index, query, opts)
    response
  end

  defp ids(response), do: Enum.map(response.results, &{&1.cassette, &1.operation_id})

  defp put(document, path, value),
    do: put_in(document, Enum.map(path, &Access.key(&1, %{})), value)

  describe "scopes" do
    test "are required, and never default to all operations" do
      index = incus!(start_index!())

      assert_raise ArgumentError, ~r/:scopes is required/, fn ->
        Tama.Dex.search(index, "image", [])
      end

      assert_raise ArgumentError, ~r/list of strings/, fn ->
        Tama.Dex.search(index, "image", scopes: "incus.read")
      end

      assert_raise ArgumentError, ~r/list of strings/, fn ->
        Tama.Dex.search(index, "image", scopes: [:read])
      end
    end

    test "a caller without the delete scope never sees delete operations" do
      index = incus!(start_index!())

      assert search!(index, "delete", scopes: ["incus.read"]) == %{results: [], truncated: false}

      listed = search!(index, nil, scopes: ["incus.read"], limit: 20)
      assert ids(listed) == [{"opsmaru_incus", "incus_instance_list"}]
    end

    test "an operation is visible only when every one of its scopes is held" do
      doc =
        "profile/valid/opsmaru_incus.json"
        |> fixture()
        |> put(@op_path ++ ["x-tama-scopes"], ["incus.delete", "incus.admin"])

      index = load!(start_index!(), doc, "opsmaru_incus")

      delete = {"opsmaru_incus", "incus_image_delete"}
      refute delete in ids(search!(index, "image", scopes: @incus_scopes))
      assert delete in ids(search!(index, "image", scopes: ["incus.admin" | @incus_scopes]))
    end

    test "hidden operations never affect results, counts or flags" do
      full = incus!(start_index!())

      visible_only =
        "profile/valid/opsmaru_incus.json"
        |> fixture()
        |> Map.update!("paths", &Map.take(&1, ["/operations/incus_instance_list"]))

      partial = load!(start_index!(), visible_only, "opsmaru_incus")

      for query <- [nil, "incus", "instance", "delete", "fingerprint", "image"],
          limit <- [1, 5, 20] do
        opts = [scopes: ["incus.read"], limit: limit]
        assert search!(full, query, opts) == search!(partial, query, opts)
      end
    end
  end

  describe "query text" do
    setup do
      %{index: start_index!() |> incus!() |> macus!()}
    end

    test "is reduced to quoted prefix terms joined with AND" do
      assert Search.match_expression(~S|instance" OR NEAR(* -delete|) ==
               ~S|"instance"* AND "or"* AND "near"* AND "delete"*|

      assert Search.match_expression("Fingerprint fingerprint") == ~S|"fingerprint"*|
      assert Search.match_expression("Größe 42") == ~S|"größe"* AND "42"*|
      assert Search.match_expression(~S|"*-:()|) == nil
      assert Search.match_expression("") == nil
    end

    test "query syntax in caller text is inert", %{index: index} do
      for text <- [
            ~S|instance" OR NEAR(* -delete|,
            ~S|"|,
            "NEAR",
            "inst*",
            "operation_id:incus",
            "-instance",
            "instance OR image",
            "(instance",
            "instance)",
            "{instance}",
            "^instance",
            "instance AND",
            "NOT instance"
          ] do
        assert {:ok, %{results: _results}} = Tama.Dex.search(index, text, scopes: @all_scopes)
      end

      assert ids(search!(index, "inst*", scopes: @all_scopes)) ==
               ids(search!(index, "inst", scopes: @all_scopes))

      assert search!(index, "instance OR image", scopes: @all_scopes) ==
               search!(index, "instance or image", scopes: @all_scopes)
    end

    test "a punctuation-only query lists like an empty query", %{index: index} do
      empty = search!(index, nil, scopes: @all_scopes, limit: 20)

      assert search!(index, ~S|"*-:()|, scopes: @all_scopes, limit: 20) == empty
      assert search!(index, "", scopes: @all_scopes, limit: 20) == empty
      assert search!(index, "   ", scopes: @all_scopes, limit: 20) == empty
    end

    test "an empty query lists in (cassette, operation_id) order", %{index: index} do
      assert ids(search!(index, nil, scopes: @all_scopes, limit: 20)) == [
               {"macus", "instance_start"},
               {"macus", "list_instances"},
               {"macus", "runtime_status"},
               {"opsmaru_incus", "incus_image_delete"},
               {"opsmaru_incus", "incus_instance_create"},
               {"opsmaru_incus", "incus_instance_exec"},
               {"opsmaru_incus", "incus_instance_list"}
             ]
    end

    test "query text over 512 bytes raises", %{index: index} do
      assert {:ok, _response} =
               Tama.Dex.search(index, String.duplicate("a", 512), scopes: @all_scopes)

      assert_raise ArgumentError, ~r/over 512 bytes/, fn ->
        Tama.Dex.search(index, String.duplicate("é", 257), scopes: @all_scopes)
      end

      assert_raise ArgumentError, ~r/must be a string/, fn ->
        Tama.Dex.search(index, :instance, scopes: @all_scopes)
      end

      assert_raise ArgumentError, ~r/UTF-8/, fn ->
        Tama.Dex.search(index, <<0xFF>>, scopes: @all_scopes)
      end
    end
  end

  describe "ranking" do
    test "results from two cassettes share one ranking, each naming its cassette" do
      index = start_index!() |> incus!() |> macus!()
      response = search!(index, "instance", scopes: @all_scopes, limit: 20)

      assert response.results |> Enum.map(& &1.cassette) |> Enum.uniq() |> Enum.sort() ==
               ["macus", "opsmaru_incus"]

      assert length(response.results) == 5
      assert Enum.all?(response.results, &Map.has_key?(&1, :cassette_version))
    end

    test "the cassette filter returns only that cassette" do
      index = start_index!() |> incus!() |> macus!()
      response = search!(index, "instance", scopes: @all_scopes, cassette: "macus", limit: 20)

      assert Enum.map(response.results, & &1.cassette) |> Enum.uniq() == ["macus"]
      assert length(response.results) == 2

      assert_raise ArgumentError, fn ->
        Tama.Dex.search(index, "x", scopes: [], cassette: "Bad")
      end
    end

    test "an input field name finds the operations that take it" do
      doc =
        document("hw", ["device_get", "device_list"])
        |> put(
          [
            "paths",
            "/operations/device_get",
            "post",
            "requestBody",
            "content",
            "application/json",
            "schema",
            "properties"
          ],
          %{"serial_number" => %{"type" => "string"}}
        )

      index = load!(start_index!(), doc, "hw")

      assert ids(search!(index, "serial", scopes: ["test.read"])) == [{"hw", "device_get"}]
      assert ids(search!(index, "fingerprint", scopes: @incus_scopes)) == []

      index = incus!(index)

      assert {"opsmaru_incus", "incus_image_delete"} in ids(
               search!(index, "fingerprint", scopes: @incus_scopes)
             )
    end

    test "an exact operationId ranks first, ordered by cassette across cassettes" do
      ids = ["instance_list", "list_instance_logs", "list_instance_names"]

      summary = fn _id ->
        "List instance logs and names, list everything about an instance list"
      end

      index =
        start_index!()
        |> load!(document("zeta", ids, summary: summary), "zeta")
        |> load!(document("alpha", ids, summary: summary), "alpha")

      assert [first, second | _rest] =
               ids(search!(index, "instance_list", scopes: ["test.read"], limit: 20))

      assert first == {"alpha", "instance_list"}
      assert second == {"zeta", "instance_list"}

      assert [{"alpha", "list_instance_logs"} | _rest] =
               ids(search!(index, "list_instance_logs", scopes: ["test.read"], limit: 20))
    end

    test "the operation ID weighs more than the description" do
      doc =
        document("w", ["zebra_get", "horse_get"])
        |> put(
          ["paths", "/operations/horse_get", "post", "description"],
          "Gets a horse, not a zebra."
        )

      index = load!(start_index!(), doc, "w")

      assert ids(search!(index, "zebra", scopes: ["test.read"])) == [
               {"w", "zebra_get"},
               {"w", "horse_get"}
             ]
    end

    test "equal ranks are ordered by cassette, then operationId" do
      same = fn _id -> "Same summary" end

      index =
        start_index!()
        |> load!(document("b", ["op_two", "op_one"], summary: same), "beta")
        |> load!(document("a", ["op_two", "op_one"], summary: same), "alpha")

      assert ids(search!(index, "same", scopes: ["test.read"], limit: 20)) == [
               {"alpha", "op_one"},
               {"alpha", "op_two"},
               {"beta", "op_one"},
               {"beta", "op_two"}
             ]
    end
  end

  describe "filters and limits" do
    setup do
      %{index: start_index!() |> incus!() |> macus!()}
    end

    test "limit defaults to 5 and must be 1 to 20", %{index: index} do
      many = document("many", Enum.map(1..25, &"op_#{&1}"))
      load!(index, many, "many")

      assert length(search!(index, nil, scopes: ["test.read"]).results) == 5
      assert length(search!(index, nil, scopes: ["test.read"], limit: 20).results) == 20
      assert length(search!(index, nil, scopes: ["test.read"], limit: 1).results) == 1

      for limit <- [0, 21, -1, "5", 2.0, nil] do
        assert_raise ArgumentError, ~r/:limit/, fn ->
          Tama.Dex.search(index, nil, scopes: ["test.read"], limit: limit)
        end
      end
    end

    test "the source and tags filters narrow results", %{index: index} do
      assert ids(search!(index, nil, scopes: @all_scopes, source: "macus", limit: 20)) |> length() ==
               3

      assert ids(search!(index, nil, scopes: @all_scopes, tags: ["instance"], limit: 20)) == [
               {"opsmaru_incus", "incus_instance_create"},
               {"opsmaru_incus", "incus_instance_exec"},
               {"opsmaru_incus", "incus_instance_list"}
             ]

      assert ids(search!(index, nil, scopes: @all_scopes, tags: ["instance", "exec"], limit: 20)) ==
               [
                 {"opsmaru_incus", "incus_instance_exec"}
               ]

      assert search!(index, nil, scopes: @all_scopes, tags: ["missing"]).results == []

      assert_raise ArgumentError, fn -> Tama.Dex.search(index, nil, scopes: [], tags: "image") end

      assert_raise ArgumentError, fn ->
        Tama.Dex.search(index, nil, scopes: [], tags: [:image])
      end

      assert_raise ArgumentError, fn ->
        Tama.Dex.search(index, nil, scopes: [], source: :macus)
      end
    end

    test "destructive operations can be excluded", %{index: index} do
      opts = [scopes: @incus_scopes, cassette: "opsmaru_incus", limit: 20]

      assert {"opsmaru_incus", "incus_image_delete"} in ids(search!(index, nil, opts))

      refute {"opsmaru_incus", "incus_image_delete"} in ids(
               search!(index, nil, [include_destructive: false] ++ opts)
             )

      assert_raise ArgumentError, ~r/boolean/, fn ->
        Tama.Dex.search(index, nil, [include_destructive: "no"] ++ opts)
      end
    end

    test "deprecated operations are excluded unless requested" do
      doc =
        document("old", ["old_op", "new_op"])
        |> put(["paths", "/operations/old_op", "post", "deprecated"], true)

      index = load!(start_index!(), doc, "old")

      assert ids(search!(index, nil, scopes: ["test.read"])) == [{"old", "new_op"}]

      response = search!(index, nil, scopes: ["test.read"], include_deprecated: true)
      assert ids(response) == [{"old", "new_op"}, {"old", "old_op"}]
      assert Enum.find(response.results, &(&1.operation_id == "old_op")).deprecated
    end
  end

  describe "results" do
    test "carry the fields a caller needs to choose and execute" do
      index = incus!(start_index!())

      assert %{results: [result], truncated: false} =
               search!(index, "incus_image_delete", scopes: @incus_scopes, limit: 1)

      assert %{
               cassette: "opsmaru_incus",
               cassette_version: nil,
               operation_id: "incus_image_delete",
               source: "opsmaru_incus",
               summary: "Delete an image",
               description_truncated: false,
               tags: ["image"],
               scopes: ["incus.delete"],
               destructive: true,
               deprecated: false,
               confirmation: %{field: "confirm", description: "the full fingerprint"},
               bounds: %{"max_wait_seconds" => 60},
               input_schema: %{"$defs" => %{"DeleteImage" => _schema}}
             } = result

      refute Map.has_key?(result, :schema_omitted)
      refute Map.has_key?(result, :extensions)

      without =
        search!(index, "incus_image_delete", scopes: @incus_scopes, include_schemas: false)

      refute Map.has_key?(hd(without.results), :input_schema)
      refute Map.has_key?(hd(without.results), :schema_omitted)
    end

    test "descriptions are cut to 1024 characters with a flag" do
      long = String.duplicate("ü", 1500)

      doc =
        document("long", ["long_op"])
        |> put(["paths", "/operations/long_op", "post", "description"], long)

      index = load!(start_index!(), doc, "long")

      [result] = search!(index, nil, scopes: ["test.read"]).results
      assert result.description == String.duplicate("ü", 1024)
      assert result.description_truncated

      {:ok, described} = Tama.Dex.describe(index, "long", "long_op", scopes: ["test.read"])
      assert described.description == long
      refute described.description_truncated
    end

    test "input schemas are dropped from the lowest-ranked results first" do
      ids = Enum.map(1..5, &"big_#{&1}")
      big = %{"type" => "string", "description" => String.duplicate("s", 25 * 1024)}

      doc =
        Enum.reduce(ids, document("big", ids), fn id, doc ->
          put(
            doc,
            [
              "paths",
              "/operations/#{id}",
              "post",
              "requestBody",
              "content",
              "application/json",
              "schema",
              "properties",
              "blob"
            ],
            big
          )
        end)

      index = load!(start_index!(), doc, "big")
      response = search!(index, nil, scopes: ["test.read"])

      assert ids(response) == Enum.map(ids, &{"big", &1})
      refute response.truncated
      assert byte_size(Jason.encode!(response)) <= 64 * 1024

      flags =
        Enum.map(
          response.results,
          &{Map.has_key?(&1, :input_schema), Map.get(&1, :schema_omitted, false)}
        )

      assert flags == [{true, false}, {true, false}, {false, true}, {false, true}, {false, true}]
    end

    test "results are cut, with truncated set, when even schemaless results exceed the budget" do
      ids = Enum.map(1..5, &"wide_#{&1}")
      bounds = Map.new(1..800, &{"bound_#{String.duplicate("x", 20)}_#{&1}", &1})

      doc =
        Enum.reduce(ids, document("wide", ids), fn id, doc ->
          put(doc, ["paths", "/operations/#{id}", "post", "x-tama-bounds"], bounds)
        end)

      index = load!(start_index!(), doc, "wide")
      response = search!(index, nil, scopes: ["test.read"])

      assert response.truncated
      assert byte_size(Jason.encode!(response)) <= 64 * 1024
      assert ids(response) == Enum.map(Enum.take(ids, length(response.results)), &{"wide", &1})
      assert length(response.results) in 1..4
      assert Enum.all?(response.results, & &1.schema_omitted)
    end
  end

  describe "describe" do
    setup do
      %{index: incus!(start_index!())}
    end

    test "returns a visible operation in full", %{index: index} do
      assert {:ok, operation} =
               Tama.Dex.describe(index, "opsmaru_incus", "incus_image_delete",
                 scopes: @incus_scopes
               )

      assert operation.operation_id == "incus_image_delete"
      assert operation.cassette == "opsmaru_incus"
      assert operation.identity == ["operation_id", "status"]

      assert operation.extensions == %{
               "x-opsmaru-requires" => ["DeleteImage", "GetOperationWait"]
             }

      assert %{"$ref" => "#/$defs/tama:root"} = operation.success_schema
      assert %{"$defs" => %{"Error" => _error}} = operation.error_schema
      assert %{"$defs" => %{"DeleteImage" => _input}} = operation.input_schema

      {:ok, list} =
        Tama.Dex.describe(index, "opsmaru_incus", "incus_instance_list", scopes: @incus_scopes)

      assert list.identity == []
      assert list.extensions == %{"x-opsmaru-requires" => ["GetInstances"]}
    end

    test "returns not_found for hidden or unknown operations", %{index: index} do
      assert {:error, :not_found} =
               Tama.Dex.describe(index, "opsmaru_incus", "incus_image_delete",
                 scopes: ["incus.read"]
               )

      assert {:error, :not_found} =
               Tama.Dex.describe(index, "opsmaru_incus", "missing", scopes: @incus_scopes)

      assert {:error, :not_found} =
               Tama.Dex.describe(index, "macus", "incus_image_delete", scopes: @incus_scopes)
    end

    test "requires scopes and valid names", %{index: index} do
      assert_raise ArgumentError, ~r/:scopes is required/, fn ->
        Tama.Dex.describe(index, "opsmaru_incus", "incus_image_delete", [])
      end

      assert_raise ArgumentError, fn -> Tama.Dex.describe(index, "Bad", "x", scopes: []) end

      assert_raise ArgumentError, fn ->
        Tama.Dex.describe(index, "opsmaru_incus", :x, scopes: [])
      end
    end
  end

  test "search telemetry carries the query length, never its text" do
    index = incus!(start_index!())
    ref = :telemetry_test.attach_event_handlers(self(), [[:tama_dex, :search, :stop]])

    {:ok, _response} = Tama.Dex.search(index, "secret instance", scopes: ["incus.read"])

    assert_received {[:tama_dex, :search, :stop], ^ref, %{duration: _},
                     %{query_length: 15, results: 0, truncated: false, cassette: nil, limit: 5} =
                       metadata}

    refute inspect(metadata) =~ "secret"
  end
end
