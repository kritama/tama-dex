defmodule Tama.Dex.ProfileTest do
  use ExUnit.Case, async: true

  alias Tama.Dex.Document
  alias Tama.Dex.JSON
  alias Tama.Dex.Operation
  alias Tama.Dex.Profile
  alias Tama.Dex.Profile.Issue

  @fixtures Path.expand("../../fixtures/profile", __DIR__)
  @op "/paths/~1operations~1thing_delete/post"
  @input @op <> "/requestBody/content/application~1json/schema"
  @op_path ["paths", "/operations/thing_delete", "post"]
  @input_path @op_path ++ ["requestBody", "content", "application/json", "schema"]

  defp fixture(kind, name) do
    @fixtures |> Path.join("#{kind}/#{name}.json") |> File.read!() |> Jason.decode!()
  end

  defp minimal, do: fixture("valid", "minimal")

  defp put(document, path, value) do
    put_in(document, Enum.map(path, &Access.key(&1, %{})), value)
  end

  defp issues(document) do
    assert {:error, issues} = Profile.validate(document)
    issues
  end

  defp has_issue?(issues, code, pointer) do
    Enum.any?(issues, &(&1.code == code and &1.pointer == pointer))
  end

  describe "valid documents" do
    test "an opsmaru_incus-shaped document validates and normalizes" do
      assert {:ok, %Document{} = document} = Profile.validate(fixture("valid", "opsmaru_incus"))

      assert document.profile == "tama-operations/1"
      assert document.source == "opsmaru_incus"
      assert document.title == "opsmaru_incus operations"
      assert document.version == "0.2.0"
      assert document.digest =~ ~r/^[0-9a-f]{64}$/
      assert document.digest == JSON.sha256(document.canonical_json)

      assert Enum.map(document.operations, & &1.operation_id) == [
               "incus_image_delete",
               "incus_instance_create",
               "incus_instance_exec",
               "incus_instance_list"
             ]

      list = Enum.find(document.operations, &(&1.operation_id == "incus_instance_list"))
      assert %Operation{destructive: false, confirmation: nil, identity: []} = list
      assert list.scopes == ["incus.read"]
      assert list.bounds == %{"max_items" => 500}
      assert list.source == "opsmaru_incus"
    end

    test "an input schema given by reference passes the object and confirmation rules" do
      {:ok, document} = Profile.validate(fixture("valid", "opsmaru_incus"))
      delete = Enum.find(document.operations, &(&1.operation_id == "incus_image_delete"))

      assert delete.destructive
      assert delete.confirmation == %{field: "confirm", description: "the full fingerprint"}
      assert delete.identity == ["operation_id", "status"]

      assert delete.fields == [
               %{name: "confirm", description: "Repeat the full fingerprint to confirm."},
               %{name: "fingerprint", description: "The image's full SHA-256 fingerprint."},
               %{
                 name: "project",
                 description: "The Incus project. Defaults to the client's project."
               }
             ]
    end

    test "producer extensions are preserved as opaque metadata" do
      {:ok, document} = Profile.validate(fixture("valid", "opsmaru_incus"))
      delete = Enum.find(document.operations, &(&1.operation_id == "incus_image_delete"))

      assert delete.extensions == %{"x-opsmaru-requires" => ["DeleteImage", "GetOperationWait"]}
    end

    test "bundled schemas compile and validate on their own" do
      {:ok, document} = Profile.validate(fixture("valid", "opsmaru_incus"))
      delete = Enum.find(document.operations, &(&1.operation_id == "incus_image_delete"))

      refute inspect(delete.input_schema) =~ "#/components/"
      assert {:ok, input} = JSONSchex.compile(delete.input_schema)

      assert :ok =
               JSONSchex.validate(input, %{
                 "fingerprint" => String.duplicate("a", 64),
                 "confirm" => "x"
               })

      assert {:error, _errors} =
               JSONSchex.validate(input, %{"fingerprint" => "short", "confirm" => "x"})

      assert {:ok, error} = JSONSchex.compile(delete.error_schema)
      assert {:error, _errors} = JSONSchex.validate(error, %{})
      assert :ok = JSONSchex.validate(error, %{"error" => %{"code" => "x", "message" => "y"}})
    end

    test "a schema that references no component is kept as written" do
      {:ok, document} = Profile.validate(minimal())
      [operation] = document.operations

      assert operation.success_schema ==
               get_in(
                 minimal(),
                 @op_path ++ ["responses", "200", "content", "application/json", "schema"]
               )

      assert operation.error_schema == nil
    end

    test "the digest is over canonical JSON, with sorted keys and no whitespace" do
      {:ok, document} = Profile.validate(minimal())

      # Over 32 keys, so the map's own iteration order is not sorted.
      many = Map.new(1..40, &{"k#{&1}", &1})
      {:ok, wide} = Profile.validate(put(minimal(), ["info", "x-wide"], many))
      keys = Regex.scan(~r/"(k\d+)"/, wide.canonical_json, capture: :all_but_first)
      assert List.flatten(keys) == many |> Map.keys() |> Enum.sort()

      refute document.canonical_json =~ "\n"
      refute document.canonical_json =~ ~s(": )
      assert String.starts_with?(document.canonical_json, ~s({"components":))
      assert Jason.decode!(document.canonical_json) == minimal()

      changed = put(minimal(), ["info", "version"], "1.0.1")
      assert {:ok, %{digest: other}} = Profile.validate(changed)
      refute other == document.digest
    end

    test "the profile document's example validates" do
      [example] =
        Regex.run(
          ~r/## Example\s+```json\n(.*?)```/s,
          File.read!(Path.expand("../../../docs/tama-operations-profile.md", __DIR__)),
          capture: :all_but_first
        )

      assert {:ok, %Document{}} = example |> Jason.decode!() |> Profile.validate()
    end

    test "the published JSON Schema is the one the validator uses" do
      path = Path.expand("../../../priv/profile/tama-operations-1.schema.json", __DIR__)

      assert Profile.json_schema() == path |> File.read!() |> Jason.decode!()
      assert {:ok, _schema} = JSONSchex.compile(Profile.json_schema())
      assert Profile.profile() == "tama-operations/1"
    end
  end

  # One fixture per rule: {fixture, code, pointer}.
  @invalid [
    {"unsupported_profile", :unsupported_profile, "/x-tama-profile"},
    {"missing_profile", :unsupported_profile, "/x-tama-profile"},
    {"invalid_openapi_version", :invalid_field, "/openapi"},
    {"missing_info_version", :missing_field, "/info/version"},
    {"invalid_source", :invalid_field, "/x-tama-source"},
    {"invalid_dialect", :invalid_field, "/jsonSchemaDialect"},
    {"webhooks", :unknown_field, "/webhooks"},
    {"unknown_document_extension", :unknown_extension, "/x-tama-cassette"},
    {"non_operation_path", :invalid_path, "/paths/~1things~1thing_delete"},
    {"extra_method", :unknown_field, "/paths/~1operations~1thing_delete/get"},
    {"path_id_mismatch", :operation_id_mismatch, @op <> "/operationId"},
    {"duplicate_operation_id", :duplicate_operation_id,
     "/paths/~1operations~1thing_remove/post/operationId"},
    {"missing_summary", :missing_field, @op <> "/summary"},
    {"long_summary", :invalid_field, @op <> "/summary"},
    {"missing_description", :missing_field, @op <> "/description"},
    {"invalid_tags", :invalid_field, @op <> "/tags/0"},
    {"unknown_operation_field", :unknown_field, @op <> "/parameters"},
    {"unknown_operation_extension", :unknown_extension, @op <> "/x-tama-retry"},
    {"request_body_not_required", :invalid_field, @op <> "/requestBody/required"},
    {"request_body_two_media_types", :unknown_field, @op <> "/requestBody/content/text~1plain"},
    {"input_not_object", :invalid_input_schema, @input},
    {"missing_success_response", :missing_field, @op <> "/responses/200"},
    {"extra_response", :unknown_field, @op <> "/responses/404"},
    {"response_missing_description", :missing_field, @op <> "/responses/200/description"},
    {"empty_scopes", :invalid_field, @op <> "/x-tama-scopes"},
    {"duplicate_scopes", :invalid_field, @op <> "/x-tama-scopes"},
    {"invalid_scope", :invalid_field, @op <> "/x-tama-scopes/0"},
    {"missing_destructive", :missing_field, @op <> "/x-tama-destructive"},
    {"destructive_not_boolean", :invalid_field, @op <> "/x-tama-destructive"},
    {"confirmation_missing_field", :invalid_confirmation, @op <> "/x-tama-confirmation/field"},
    {"confirmation_not_required", :invalid_confirmation, @op <> "/x-tama-confirmation/field"},
    {"confirmation_not_string", :invalid_confirmation, @op <> "/x-tama-confirmation/field"},
    {"confirmation_in_allof", :invalid_confirmation, @op <> "/x-tama-confirmation/field"},
    {"confirmation_long_description", :invalid_field, @op <> "/x-tama-confirmation/description"},
    {"negative_bound", :invalid_field, @op <> "/x-tama-bounds/max_items"},
    {"invalid_bound_key", :invalid_field, @op <> "/x-tama-bounds/MaxItems"},
    {"identity_undeclared", :invalid_identity, @op <> "/x-tama-identity/0"},
    {"too_many_identity_names", :invalid_field, @op <> "/x-tama-identity"},
    {"external_reference", :external_reference, @input <> "/properties/name/$ref"},
    {"relative_file_reference", :external_reference, @input <> "/properties/name/$ref"},
    {"invalid_local_reference", :invalid_reference, @input <> "/properties/name/$ref"},
    {"unresolved_reference", :unresolved_reference, @input <> "/properties/name/$ref"},
    {"component_external_reference", :external_reference, "/components/schemas/Name/$ref"},
    {"schema_id", :invalid_reference, @input <> "/$id"},
    {"schema_compile_failure", :schema_compile_failed, @input},
    {"invalid_component_name", :invalid_field, "/components/schemas/Bad Name"}
  ]

  describe "invalid documents" do
    for {name, code, pointer} <- @invalid do
      test "#{name} fails with #{code}" do
        issues = issues(fixture("invalid", unquote(name)))

        assert has_issue?(issues, unquote(code), unquote(pointer)),
               "expected #{unquote(code)} at #{unquote(pointer)}, got: #{inspect(issues)}"
      end
    end

    test "every invalid fixture is covered" do
      files =
        @fixtures
        |> Path.join("invalid/*.json")
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".json"))
        |> Enum.sort()

      assert files == @invalid |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end

    test "an unsupported profile is the only issue, and no operation is read" do
      document =
        fixture("invalid", "unsupported_profile")
        |> put(@op_path ++ ["summary"], nil)
        |> put(["paths", "/elsewhere"], %{})

      assert [%Issue{code: :unsupported_profile}] = issues(document)
    end

    test "a path whose operationId disagrees points at that operation" do
      [issue] = issues(fixture("invalid", "path_id_mismatch"))
      assert issue.pointer == @op <> "/operationId"
      assert issue.message =~ "thing_remove"
    end

    test "a duplicate operationId also reports the path-suffix rule it breaks" do
      issues = issues(fixture("invalid", "duplicate_operation_id"))
      pointer = "/paths/~1operations~1thing_remove/post/operationId"

      assert has_issue?(issues, :duplicate_operation_id, pointer)
      assert has_issue?(issues, :operation_id_mismatch, pointer)
    end

    test "a broken component is reported once, at the component" do
      issues = issues(fixture("invalid", "component_external_reference"))
      assert Enum.map(issues, & &1.pointer) == ["/components/schemas/Name/$ref"]
    end

    test "external references are rejected before any schema is compiled or fetched" do
      issues = issues(fixture("invalid", "external_reference"))

      assert has_issue?(issues, :external_reference, @input <> "/properties/name/$ref")
      refute Enum.any?(issues, &(&1.code == :schema_compile_failed))
    end

    test "$ref is read through, but compositions are not" do
      by_reference =
        minimal()
        |> put(@input_path, %{"$ref" => "#/components/schemas/Delete", "title" => "Delete"})
        |> put(["components", "schemas", "Delete"], get_in(minimal(), @input_path))

      assert {:ok, _document} = Profile.validate(by_reference)

      chained =
        by_reference
        |> put(["components", "schemas", "Alias"], %{"$ref" => "#/components/schemas/Delete"})
        |> put(@input_path, %{"$ref" => "#/components/schemas/Alias"})

      assert {:ok, _document} = Profile.validate(chained)

      with_siblings = put(by_reference, @input_path ++ ["minProperties"], 1)
      issues = issues(with_siblings)
      assert has_issue?(issues, :invalid_input_schema, @input)
      assert has_issue?(issues, :invalid_confirmation, @op <> "/x-tama-confirmation/field")

      cyclic =
        minimal()
        |> put(["components", "schemas", "A"], %{"$ref" => "#/components/schemas/B"})
        |> put(["components", "schemas", "B"], %{"$ref" => "#/components/schemas/A"})
        |> put(@input_path, %{"$ref" => "#/components/schemas/A"})

      assert has_issue?(issues(cyclic), :invalid_input_schema, @input)
    end

    test "a confirmation property given by reference is read through" do
      document =
        minimal()
        |> put(@input_path ++ ["properties", "confirm"], %{"$ref" => "#/components/schemas/Name"})

      assert {:ok, _document} = Profile.validate(document)
    end

    test "identity names may come from the default schema" do
      document =
        minimal()
        |> put(@op_path ++ ["responses", "default"], %{
          "description" => "Error",
          "content" => %{
            "application/json" => %{
              "schema" => %{
                "type" => "object",
                "properties" => %{"error" => %{"type" => "object"}}
              }
            }
          }
        })
        |> put(@op_path ++ ["x-tama-identity"], ["status", "error"])

      assert {:ok, %{operations: [operation]}} = Profile.validate(document)
      assert operation.identity == ["status", "error"]
      assert operation.error_schema["properties"]["error"] == %{"type" => "object"}
    end
  end

  describe "reporting" do
    test "several defects are reported together, with the issues they imply" do
      big = %{"type" => "string", "description" => String.duplicate("x", 256 * 1024)}

      document =
        minimal()
        |> put(["paths", "/operations/thing_remove", "post"], get_in(minimal(), @op_path))
        |> Map.update!("paths", fn paths ->
          update_in(paths, ["/operations/thing_delete", "post"], &Map.delete(&1, "summary"))
        end)
        |> put(@input_path ++ ["properties", "name"], big)

      issues = issues(document)
      remove = "/paths/~1operations~1thing_remove/post/operationId"

      assert has_issue?(issues, :duplicate_operation_id, remove)
      assert has_issue?(issues, :operation_id_mismatch, remove)
      assert has_issue?(issues, :missing_field, @op <> "/summary")
      assert has_issue?(issues, :schema_too_large, @input)
      assert issues == Enum.sort_by(issues, &{&1.pointer, &1.code})
    end

    test "a schema is measured with the components it references" do
      big = %{"type" => "string", "description" => String.duplicate("x", 200 * 1024)}

      document =
        minimal()
        |> put(["components", "schemas", "Big"], big)
        |> put(["components", "schemas", "Name"], %{
          "type" => "string",
          "description" => String.duplicate("y", 100 * 1024)
        })
        |> put(@input_path ++ ["properties", "big"], %{"$ref" => "#/components/schemas/Big"})

      assert has_issue?(issues(document), :schema_too_large, @input)
    end

    test "an operation's other extensions are limited to 16 KiB" do
      document = put(minimal(), @op_path ++ ["x-example-notes"], String.duplicate("n", 16 * 1024))
      assert has_issue?(issues(document), :extensions_too_large, @op)

      fits = put(minimal(), @op_path ++ ["x-example-notes"], String.duplicate("n", 1024))
      assert {:ok, %{operations: [operation]}} = Profile.validate(fits)
      assert Map.keys(operation.extensions) == ["x-example-notes"]
    end

    test "a document over 4 MiB fails with a limit issue, without compiling any schema" do
      document =
        minimal()
        |> put(["info", "description"], String.duplicate("d", 4 * 1024 * 1024))
        |> put(@input_path ++ ["properties", "confirm", "type"], "strin")

      assert [%Issue{code: :document_too_large, pointer: ""}] = issues(document)
    end

    test "a document over 1024 operations fails with a limit issue" do
      operation = get_in(minimal(), @op_path)

      paths =
        Map.new(1..1025, fn n ->
          id = "thing_#{n}"
          {"/operations/#{id}", %{"post" => Map.put(operation, "operationId", id)}}
        end)

      assert [%Issue{code: :too_many_operations, pointer: "/paths"}] =
               issues(Map.put(minimal(), "paths", paths))
    end

    test "a document that is not a map is rejected" do
      assert {:error, [%Issue{code: :invalid_document, pointer: ""}]} = Profile.validate("{}")
      assert {:error, [%Issue{code: :invalid_document}]} = Profile.validate(nil)
    end

    test "values that are not JSON data are rejected" do
      document =
        minimal()
        |> put(["info", "title"], :atom)
        |> put(["info", "contact"], {:tuple})
        |> put(["info", "license"], %{name: "atom key"})
        |> put(["info", "termsOfService"], <<0xFF>>)
        |> put(["info", "x-list"], [1, 2.5, true, nil, self()])

      issues = issues(document)
      assert Enum.all?(issues, &(&1.code == :invalid_json))

      assert Enum.sort(Enum.map(issues, & &1.pointer)) ==
               Enum.sort([
                 "/info/title",
                 "/info/contact",
                 "/info/license",
                 "/info/termsOfService",
                 "/info/x-list/4"
               ])
    end

    test "non-JSON values are reported up to a bound" do
      document = put(minimal(), ["info", "x-many"], List.duplicate(:atom, 100))
      assert length(issues(document)) == 32
    end

    test "messages are at most 256 bytes" do
      long_id = String.duplicate("é", 200)

      document =
        minimal()
        |> put(@op_path ++ ["x-tama-confirmation", "field"], long_id)
        |> put(["x-tama-source"], String.duplicate("Ω", 300))

      issues = issues(document)
      assert length(issues) >= 2

      for issue <- issues do
        assert byte_size(issue.message) <= 256
        assert String.valid?(issue.message)
      end
    end
  end
end
