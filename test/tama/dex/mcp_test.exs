defmodule Tama.Dex.MCPTest do
  use ExUnit.Case, async: true

  import Tama.Dex.TestSupport.Documents

  alias Tama.Dex.Index
  alias Tama.Dex.MCP
  alias Tama.Dex.TestSupport.Context
  alias Tama.Dex.TestSupport.CountingExecutor
  alias Tama.Dex.TestSupport.HostExecute
  alias Tama.Dex.TestSupport.HostSearch
  alias Tama.Dex.TestSupport.HostServer

  @fingerprint String.duplicate("a", 64)

  setup do
    index = start_supervised!({Index, path: :memory}, id: make_ref())

    {:ok, _loaded} =
      Tama.Dex.load(index, fixture("profile/valid/opsmaru_incus.json"), cassette: "opsmaru_incus")

    {:ok, _loaded} =
      Tama.Dex.load(index, document("macus", ["list_instances", "runtime_start"]),
        cassette: "macus"
      )

    %{index: index}
  end

  defp caller(scopes), do: %Context{request_id: 1, claims: %{"sub" => "agent-7"}, scopes: scopes}

  defp executors(respond \\ nil) do
    opts = if respond, do: [test: self(), respond: respond], else: [test: self()]
    %{"opsmaru_incus" => {CountingExecutor, opts}, "macus" => {CountingExecutor, opts}}
  end

  defp compile(schema) do
    {:ok, compiled} = JSONSchex.compile(schema, draft: "draft2020_12")
    compiled
  end

  defp valid?(schema, value), do: JSONSchex.validate(compile(schema), value) == :ok

  defp assert_search_output(response) do
    assert valid?(MCP.search_tool().output_schema, response), inspect(response)
    assert response == response |> Jason.encode!() |> Jason.decode!()
    response
  end

  defp assert_execute_output(response) do
    assert valid?(MCP.execute_tool().output_schema, response), inspect(response)
    assert response == response |> Jason.encode!() |> Jason.decode!()
    response
  end

  defp search(index, arguments, scopes \\ ["incus.read", "test.read"]) do
    index |> MCP.handle_search(arguments, caller(scopes)) |> assert_search_output()
  end

  defp execute(index, arguments, opts \\ []) do
    scopes = Keyword.get(opts, :scopes, ["incus.read", "incus.exec", "incus.delete", "test.read"])
    executors = Keyword.get(opts, :executors, executors())

    index
    |> MCP.handle_execute(arguments, Keyword.get(opts, :caller, caller(scopes)), executors)
    |> assert_execute_output()
  end

  defp delete_arguments(input \\ %{"fingerprint" => @fingerprint, "confirm" => @fingerprint}) do
    %{"cassette" => "opsmaru_incus", "operation_id" => "incus_image_delete", "input" => input}
  end

  defp exec_arguments do
    %{
      "cassette" => "opsmaru_incus",
      "operation_id" => "incus_instance_exec",
      "input" => %{"instance" => "web-1", "command" => ["uptime"]}
    }
  end

  defp refute_executed, do: refute_received({:executed, _call, _input})

  def lookup_handler(_event, _measurements, _metadata, test) do
    if self() == test, do: send(test, :looked_up)
  end

  describe "tool definitions" do
    test "are data with the definition fields" do
      for {tool, name} <- [{MCP.search_tool(), "search"}, {MCP.execute_tool(), "execute"}] do
        assert tool.name == name

        assert Map.keys(tool) |> Enum.sort() ==
                 [:annotations, :description, :input_schema, :name, :output_schema, :title]

        assert is_binary(tool.title) and is_binary(tool.description)

        assert Enum.all?(tool.annotations, fn {key, value} ->
                 is_atom(key) and is_boolean(value)
               end)

        for schema <- [tool.input_schema, tool.output_schema] do
          assert schema["type"] == "object"
          assert schema == schema |> Jason.encode!() |> Jason.decode!()
          assert {:ok, _compiled} = JSONSchex.compile(schema, draft: "draft2020_12")
        end
      end
    end

    test "search is read-only and execute is not" do
      assert MCP.search_tool().annotations.readOnlyHint
      refute MCP.search_tool().annotations.destructiveHint
      refute MCP.execute_tool().annotations.readOnlyHint
      assert MCP.execute_tool().annotations.destructiveHint
    end

    test "the search input accepts its arguments and bounds the limit" do
      schema = MCP.search_tool().input_schema

      assert valid?(schema, %{})

      assert valid?(schema, %{
               "query" => "instances",
               "cassette" => "opsmaru_incus",
               "source" => "opsmaru_incus",
               "tags" => ["incus"],
               "limit" => 20,
               "include_schemas" => false
             })

      refute valid?(schema, %{"limit" => 0})
      refute valid?(schema, %{"limit" => 21})
      refute valid?(schema, %{"cassette" => "Not A Cassette"})
    end

    test "the execute input requires cassette, operation_id and input" do
      schema = MCP.execute_tool().input_schema
      arguments = %{"cassette" => "macus", "operation_id" => "list_instances", "input" => %{}}

      assert valid?(schema, arguments)

      for key <- Map.keys(arguments) do
        refute valid?(schema, Map.delete(arguments, key))
      end

      refute valid?(schema, Map.put(arguments, "input", []))
    end

    test "both input schemas reject unknown properties" do
      refute valid?(MCP.search_tool().input_schema, %{"scopes" => ["incus.delete"]})

      refute valid?(MCP.execute_tool().input_schema, %{
               "cassette" => "macus",
               "operation_id" => "list_instances",
               "input" => %{},
               "scopes" => ["incus.delete"]
             })
    end
  end

  describe "a host's tool modules" do
    test "advertise exactly the two tools, with schemas identical to tama-dex's" do
      tools = HostServer.tools_list()

      assert Enum.map(tools, & &1["name"]) |> Enum.sort() == ["execute", "search"]

      for {module, tool} <- [{HostSearch, MCP.search_tool()}, {HostExecute, MCP.execute_tool()}] do
        definition = module.definition()

        assert definition["inputSchema"] === tool.input_schema
        assert definition["outputSchema"] === tool.output_schema
        assert definition["title"] == tool.title
        assert definition["description"] == tool.description
        assert definition["annotations"] == tool.annotations
      end
    end

    test "need the definitions injected as literals" do
      source = """
      defmodule Tama.Dex.MCPTest.NotLiteral do
        use Tama.Dex.TestSupport.HostTool, scopes: [], title: "t", description: "d", annotations: []
        raw_input_schema(Tama.Dex.MCP.search_tool().input_schema)
      end
      """

      assert_raise CompileError, ~r/must be a literal/, fn -> Code.compile_string(source) end
    end

    test "call the handlers", %{index: index} do
      context = caller(["test.read"])

      assert %{"results" => [_one, _two]} =
               HostSearch.call(index, %{"cassette" => "macus"}, context)

      arguments = %{"cassette" => "macus", "operation_id" => "list_instances", "input" => %{}}

      assert %{"result" => %{}} = HostExecute.call(index, arguments, context, executors())
    end
  end

  describe "handle_search/3" do
    test "filters by the caller's verified scopes", %{index: index} do
      %{"results" => results, "truncated" => false} =
        search(index, %{"limit" => 20}, ["incus.read"])

      assert Enum.map(results, & &1["operation_id"]) == ["incus_instance_list"]
      assert [%{"cassette" => "opsmaru_incus", "scopes" => ["incus.read"]}] = results
    end

    test "returns JSON-safe results naming their cassette", %{index: index} do
      %{"results" => [result]} =
        search(index, %{"query" => "image delete"}, ["incus.delete", "incus.read"])

      assert result["cassette"] == "opsmaru_incus"
      assert result["operation_id"] == "incus_image_delete"

      assert result["confirmation"] == %{
               "field" => "confirm",
               "description" => "the full fingerprint"
             }

      assert result["destructive"] == true
      assert is_map(result["input_schema"])
    end

    test "applies the tool's arguments", %{index: index} do
      %{"results" => results} = search(index, %{"cassette" => "macus", "limit" => 1})
      assert [%{"cassette" => "macus", "operation_id" => "list_instances"}] = results

      %{"results" => results} = search(index, %{"source" => "macus", "include_schemas" => false})
      assert length(results) == 2
      refute Enum.any?(results, &Map.has_key?(&1, "input_schema"))

      %{"results" => results} = search(index, %{"tags" => ["test"]})
      assert Enum.all?(results, &(&1["source"] == "macus"))
    end

    test "a trimmed response still matches the output schema", %{index: index} do
      ids = Enum.map(1..5, &"big_#{&1}")
      big = %{"type" => "string", "description" => String.duplicate("s", 25 * 1024)}

      doc =
        Enum.reduce(ids, document("big", ids), fn id, doc ->
          path = ["/operations/#{id}", "post", "requestBody", "content", "application/json"]
          update_in(doc, ["paths" | path] ++ ["schema", "properties"], &Map.put(&1, "blob", big))
        end)

      {:ok, _loaded} = Tama.Dex.load(index, doc, cassette: "big")

      %{"results" => results} = search(index, %{"cassette" => "big"})
      assert length(results) == 5
      assert Enum.any?(results, &(&1["schema_omitted"] == true))
    end

    test "a query over 512 bytes is invalid_arguments", %{index: index} do
      query = String.duplicate("é", 300)
      assert valid?(MCP.search_tool().input_schema, %{"query" => query})

      assert %{"error" => error} = search(index, %{"query" => query})

      assert error == %{
               "kind" => "invalid_arguments",
               "dispatched" => false,
               "message" => "The query is over 512 bytes.",
               "details" => %{
                 "issues" => [%{"pointer" => "/query", "message" => "must be at most 512 bytes"}],
                 "issues_truncated" => false
               }
             }
    end

    test "arguments that fail the tool schema are invalid_arguments", %{index: index} do
      for arguments <- [
            %{"limit" => 21},
            %{"scopes" => ["incus.delete"]},
            %{"tags" => "incus"},
            %{limit: 3},
            ["query"],
            nil
          ] do
        assert %{"error" => %{"kind" => "invalid_arguments", "dispatched" => false}} =
                 search(index, arguments)
      end

      assert %{"error" => %{"details" => %{"issues" => [issue]}}} =
               search(index, %{"limit" => "five"})

      assert issue == %{"pointer" => "/limit", "message" => "must be of type integer"}
    end

    test "a caller without a scope list raises", %{index: index} do
      for caller <- [%{}, %{scopes: nil}, %{scopes: "incus.read"}, %{scopes: [:read]}, nil] do
        assert_raise ArgumentError, fn -> MCP.handle_search(index, %{}, caller) end
      end
    end

    test "the raised error never shows the caller", %{index: index} do
      caller = %{scopes: nil, claims: %{"token" => "secret-token"}}

      error = assert_raise ArgumentError, fn -> MCP.handle_search(index, %{}, caller) end
      refute Exception.message(error) =~ "secret-token"
    end
  end

  describe "handle_execute/4" do
    test "a tool scope without the operation's scope is not_found", %{index: index} do
      response = execute(index, delete_arguments(), scopes: ["incus.read"])

      assert response == %{
               "error" => %{
                 "kind" => "not_found",
                 "dispatched" => false,
                 "message" => "No such operation is available to this caller."
               }
             }

      refute_executed()
    end

    test "passes a TamaMCP-style context as call.context", %{index: index} do
      context = caller(["incus.read"])

      arguments = %{
        "cassette" => "opsmaru_incus",
        "operation_id" => "incus_instance_list",
        "input" => %{}
      }

      respond = fn _call, _input -> {:ok, %{"instances" => []}} end

      response = execute(index, arguments, caller: context, executors: executors(respond))

      assert response == %{
               "cassette" => "opsmaru_incus",
               "operation_id" => "incus_instance_list",
               "source" => "opsmaru_incus",
               "result" => %{"instances" => []}
             }

      assert_received {:executed, call, %{}}
      assert call.context === context
      assert call.scopes == ["incus.read"]
    end

    test "returns the executor's own error with dispatched", %{index: index} do
      error = %{"error" => %{"code" => "busy", "message" => "Instance is busy"}}
      respond = fn _call, _input -> {:error, error} end

      response = execute(index, exec_arguments(), executors: executors(respond))

      assert response == %{
               "cassette" => "opsmaru_incus",
               "operation_id" => "incus_instance_exec",
               "source" => "opsmaru_incus",
               "operation_error" => error,
               "dispatched" => true
             }
    end

    test "encodes tama-dex errors as error objects", %{index: index} do
      assert %{"error" => %{"kind" => "confirmation_required", "dispatched" => false} = error} =
               execute(index, delete_arguments(%{"fingerprint" => @fingerprint}))

      assert error["details"] == %{"field" => "confirm", "description" => "the full fingerprint"}

      assert %{"error" => %{"kind" => "invalid_input", "details" => details}} =
               execute(index, delete_arguments(%{"fingerprint" => "short", "confirm" => "x"}))

      assert details == %{
               "issues" => [
                 %{"pointer" => "/fingerprint", "message" => "fails the pattern keyword"}
               ],
               "issues_truncated" => false
             }

      assert %{"error" => %{"kind" => "no_executor", "details" => %{"source" => "opsmaru_incus"}}} =
               execute(index, exec_arguments(), executors: %{})

      refute_executed()
    end

    test "encodes dispatched errors with their kind and flag", %{index: index} do
      raising = fn _call, _input -> raise "boom" end

      assert %{"error" => error} = execute(index, exec_arguments(), executors: executors(raising))
      assert error["kind"] == "dispatch_failed"
      assert error["dispatched"] == true
      assert error["details"] == %{"exception_kind" => "error"}
      assert error["message"] =~ "reconcile"
      refute error["message"] =~ "boom"

      wrong = fn _call, _input -> {:ok, %{"operation_id" => "op-9", "exit_code" => "zero"}} end

      assert %{"error" => error} = execute(index, exec_arguments(), executors: executors(wrong))
      assert error["kind"] == "invalid_output"
      assert error["dispatched"] == true
      assert error["details"] == %{"identity" => %{"operation_id" => "op-9"}}
    end

    test "arguments that fail the tool schema are invalid_arguments, before any lookup",
         %{index: index} do
      # Other async tests execute too, so count only this process's events.
      handler = "mcp-test-#{inspect(make_ref())}"
      test = self()

      :telemetry.attach(
        handler,
        [:tama_dex, :execute, :start],
        &__MODULE__.lookup_handler/4,
        test
      )

      ok = fn _call, _input -> {:ok, %{"operation_id" => "op-1", "exit_code" => 0}} end

      for key <- ["cassette", "operation_id", "input"] do
        assert %{"error" => error} = execute(index, Map.delete(exec_arguments(), key))
        assert error["kind"] == "invalid_arguments"
        assert error["dispatched"] == false

        assert error["details"]["issues"] == [
                 %{"pointer" => "/#{key}", "message" => "is required"}
               ]
      end

      for arguments <- [
            Map.put(exec_arguments(), "scopes", ["incus.delete"]),
            Map.put(exec_arguments(), "cassette", "Opsmaru"),
            Map.put(exec_arguments(), "input", "uptime"),
            %{cassette: "opsmaru_incus"},
            "execute"
          ] do
        assert %{"error" => %{"kind" => "invalid_arguments"}} = execute(index, arguments)
      end

      refute_received :looked_up
      refute_executed()

      # A valid call is looked up, so the probe above can see one.
      assert %{"result" => _result} = execute(index, exec_arguments(), executors: executors(ok))
      assert_received :looked_up
      :telemetry.detach(handler)
    end

    test "a caller without a scope list raises", %{index: index} do
      assert_raise ArgumentError, fn ->
        MCP.handle_execute(index, exec_arguments(), %{claims: %{}}, executors())
      end

      refute_executed()
    end

    test "executors that aren't a map raise", %{index: index} do
      assert_raise ArgumentError, fn ->
        MCP.handle_execute(index, exec_arguments(), caller(["incus.exec"]), nil)
      end
    end
  end
end
