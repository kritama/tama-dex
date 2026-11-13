defmodule Tama.Dex.ExecuteTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Tama.Dex.TestSupport.Documents

  alias Tama.Dex.Call
  alias Tama.Dex.Error
  alias Tama.Dex.Index
  alias Tama.Dex.TestSupport.AcmeAdapter
  alias Tama.Dex.TestSupport.AcmeAuthorizer
  alias Tama.Dex.TestSupport.CountingExecutor
  alias Tama.Dex.TestSupport.FakeProducer
  alias Tama.Dex.TestSupport.NoCallbackExecutor

  @scopes ["incus.read", "incus.write", "incus.exec", "incus.delete"]
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

  defp executors(respond \\ nil) do
    opts = if respond, do: [test: self(), respond: respond], else: [test: self()]
    %{"opsmaru_incus" => {CountingExecutor, opts}, "macus" => {CountingExecutor, opts}}
  end

  defp execute(index, cassette, id, input, opts \\ []) do
    opts = Keyword.merge([scopes: @scopes ++ ["test.read"], executors: executors()], opts)
    Tama.Dex.execute(index, cassette, id, input, opts)
  end

  defp calls do
    receive do
      {:executed, _call, _input} -> 1 + calls()
    after
      0 -> 0
    end
  end

  defp delete_input(overrides \\ %{}) do
    Map.merge(%{"fingerprint" => @fingerprint, "confirm" => @fingerprint}, overrides)
  end

  defp exec_input, do: %{"instance" => "web-1", "command" => ["uptime"]}

  defp exec_result(overrides \\ %{}) do
    Map.merge(%{"operation_id" => "op-1", "exit_code" => 0, "stdout" => "up"}, overrides)
  end

  describe "lookup" do
    test "looks the operation up in the named cassette only", %{index: index} do
      assert {:error, %Error{kind: :not_found, dispatched: false}} =
               execute(index, "opsmaru_incus", "list_instances", %{})

      assert calls() == 0
      assert {:ok, _result} = execute(index, "macus", "list_instances", %{})
      assert calls() == 1
    end

    test "an unknown cassette or operation is not_found", %{index: index} do
      assert {:error, %Error{kind: :not_found}} = execute(index, "missing", "list_instances", %{})
      assert {:error, %Error{kind: :not_found}} = execute(index, "macus", "missing_op", %{})
      assert calls() == 0
    end

    test "an operation the caller's scopes don't allow is not_found", %{index: index} do
      assert {:error, %Error{kind: :not_found, dispatched: false} = hidden} =
               execute(index, "opsmaru_incus", "incus_image_delete", delete_input(),
                 scopes: ["incus.read"]
               )

      assert {:error, missing} =
               execute(index, "opsmaru_incus", "no_such_op", %{}, scopes: ["incus.read"])

      assert hidden == missing
      assert calls() == 0
    end
  end

  describe "executor" do
    test "a source with no entry is no_executor, naming the source", %{index: index} do
      assert {:error, %Error{kind: :no_executor, dispatched: false} = error} =
               execute(index, "macus", "list_instances", %{}, executors: %{})

      assert error.details == %{source: "macus"}
      assert error.message =~ "macus"
    end

    test "an entry that isn't a loaded module with execute/2 is no_executor", %{index: index} do
      for registration <- [
            NoCallbackExecutor,
            {NoCallbackExecutor, []},
            Module.concat(["Tama", "Dex", "NotLoaded"]),
            {CountingExecutor, :not_a_list},
            "CountingExecutor",
            nil
          ] do
        assert {:error, %Error{kind: :no_executor, dispatched: false} = error} =
                 execute(index, "macus", "list_instances", %{},
                   executors: %{"macus" => registration}
                 )

        refute error.message =~ "Executor"
        refute error.message =~ "NotLoaded"
      end

      assert calls() == 0
    end

    test "a registration with options passes them as call.opts", %{index: index} do
      opts = [test: self(), authorizer: AcmeAuthorizer]

      assert {:ok, _result} =
               execute(index, "macus", "list_instances", %{},
                 executors: %{"macus" => {CountingExecutor, opts}}
               )

      assert_received {:executed, %Call{opts: ^opts}, _input}
    end

    test "the call carries the checked scopes as given, the names, context and input", %{
      index: index
    } do
      scopes = ["incus.read", "incus.delete", "incus.read"]
      input = delete_input()
      respond = fn _call, _input -> {:ok, %{"operation_id" => "op-9", "status" => "Success"}} end

      assert {:ok, _result} =
               execute(index, "opsmaru_incus", "incus_image_delete", input,
                 scopes: scopes,
                 context: %{caller: "agent-7"},
                 executors: executors(respond)
               )

      assert_received {:executed, call, ^input}

      assert call == %Call{
               cassette: "opsmaru_incus",
               source: "opsmaru_incus",
               operation_id: "incus_image_delete",
               scopes: scopes,
               context: %{caller: "agent-7"},
               opts: [test: self(), respond: respond]
             }
    end

    test "one registration serves every cassette carrying the source", %{index: index} do
      {:ok, _loaded} =
        Tama.Dex.load(index, document("macus", ["list_instances"]), cassette: "macus_staging")

      assert {:ok, %{cassette: "macus"}} = execute(index, "macus", "list_instances", %{})

      assert {:ok, %{cassette: "macus_staging"}} =
               execute(index, "macus_staging", "list_instances", %{})

      assert_received {:executed, %Call{cassette: "macus", source: "macus"}, _input}
      assert_received {:executed, %Call{cassette: "macus_staging", source: "macus"}, _input}
    end
  end

  describe "input checks" do
    test "the input must be a JSON object within 1 MiB", %{index: index} do
      for input <- [
            "text",
            [1, 2],
            nil,
            %{instance: "web-1"},
            %{"instance" => self()},
            %{"instance" => {:tuple}},
            %{"instance" => <<0xFF>>},
            URI.parse("http://example.com"),
            %{"instance" => String.duplicate("x", 1024 * 1024)}
          ] do
        assert {:error, %Error{kind: :invalid_input, dispatched: false, details: %{}}} =
                 execute(index, "opsmaru_incus", "incus_instance_exec", input)
      end

      assert calls() == 0
    end

    test "a missing required property is invalid_input at its pointer", %{index: index} do
      assert {:error, %Error{kind: :invalid_input, dispatched: false} = error} =
               execute(index, "opsmaru_incus", "incus_instance_exec", %{"instance" => "web-1"})

      assert %{pointer: "/command", message: "is required"} in error.details.issues
      refute error.details.issues_truncated
      assert calls() == 0
    end

    test "input issues name the keyword, never the value", %{index: index} do
      input = %{
        "instance" => "web-1",
        "command" => "secret-command",
        "cwd" => 42,
        "extra" => "secret-extra"
      }

      assert {:error, %Error{kind: :invalid_input} = error} =
               execute(index, "opsmaru_incus", "incus_instance_exec", input)

      pointers = Enum.map(error.details.issues, & &1.pointer)
      assert "/command" in pointers
      assert "/cwd" in pointers
      assert "/extra" in pointers
      refute inspect(error) =~ "secret-command"
      refute inspect(error) =~ "42"
    end

    test "input issues are bounded", %{index: index} do
      properties = Map.new(1..30, &{"p#{&1}", %{"type" => "string"}})

      doc =
        document("wide", ["wide_op"])
        |> put_in(
          [
            "paths",
            "/operations/wide_op",
            "post",
            "requestBody",
            "content",
            "application/json",
            "schema"
          ],
          %{"type" => "object", "properties" => properties, "required" => Map.keys(properties)}
        )

      {:ok, _loaded} = Tama.Dex.load(index, doc, cassette: "wide")

      assert {:error, %Error{kind: :invalid_input} = error} =
               execute(index, "wide", "wide_op", %{},
                 executors: %{"wide" => {CountingExecutor, test: self()}}
               )

      assert length(error.details.issues) == 16
      assert error.details.issues_truncated
    end

    test "a missing confirmation is confirmation_required, with the field and description", %{
      index: index
    } do
      for input <- [
            %{"fingerprint" => @fingerprint},
            delete_input(%{"confirm" => ""}),
            delete_input(%{"confirm" => "   "}),
            delete_input(%{"confirm" => nil})
          ] do
        assert {:error, %Error{kind: :confirmation_required, dispatched: false} = error} =
                 execute(index, "opsmaru_incus", "incus_image_delete", input)

        assert error.details == %{field: "confirm", description: "the full fingerprint"}
        assert error.message =~ "confirm"
      end

      assert calls() == 0
    end

    test "the confirmation is checked before the input schema", %{index: index} do
      assert {:error, %Error{kind: :confirmation_required}} =
               execute(index, "opsmaru_incus", "incus_image_delete", %{"fingerprint" => 12})

      assert {:error, %Error{kind: :invalid_input}} =
               execute(
                 index,
                 "opsmaru_incus",
                 "incus_image_delete",
                 delete_input(%{"confirm" => 7})
               )

      assert calls() == 0
    end

    test "schemas compile on first execute", %{index: index} do
      cache = Index.schema_cache(index)
      assert :ets.info(cache, :size) == 0

      {:ok, _result} = execute(index, "macus", "list_instances", %{})
      assert :ets.info(cache, :size) > 0
    end
  end

  describe "dispatch" do
    test "a valid call reaches the executor once and returns its result", %{index: index} do
      respond = fn _call, _input -> {:ok, exec_result()} end

      assert {:ok, response} =
               execute(index, "opsmaru_incus", "incus_instance_exec", exec_input(),
                 executors: executors(respond)
               )

      assert response == %{
               cassette: "opsmaru_incus",
               operation_id: "incus_instance_exec",
               source: "opsmaru_incus",
               result: exec_result()
             }

      assert calls() == 1
    end

    test "a raise, exit or throw is dispatch_failed, and the executor is called once", %{
      index: index
    } do
      for {respond, kind} <- [
            {fn _call, _input -> raise "backend accepted, then failed" end, :error},
            {fn _call, _input -> exit(:backend_down) end, :exit},
            {fn _call, _input -> throw(:backend) end, :throw}
          ] do
        assert {:error, %Error{kind: :dispatch_failed, dispatched: true} = error} =
                 execute(index, "opsmaru_incus", "incus_instance_exec", exec_input(),
                   executors: executors(respond)
                 )

        assert error.details == %{exception_kind: kind}
        assert error.message =~ "reconcile"
        refute error.message =~ "backend"
        assert calls() == 1
      end
    end

    @tag timeout: 30_000
    test "a slow executor is never cut off by tama-dex", %{index: index} do
      respond = fn _call, _input ->
        Process.sleep(5_500)
        {:ok, exec_result()}
      end

      assert {:ok, %{result: %{"operation_id" => "op-1"}}} =
               execute(index, "opsmaru_incus", "incus_instance_exec", exec_input(),
                 executors: executors(respond)
               )
    end
  end

  describe "results" do
    test "an executor error matching default is returned unchanged as an operation error", %{
      index: index
    } do
      error = %{"error" => %{"code" => "not_found", "message" => "no such instance"}}
      respond = fn _call, _input -> {:error, error} end

      assert {:error, operation_error} =
               execute(index, "opsmaru_incus", "incus_instance_exec", exec_input(),
                 executors: executors(respond)
               )

      refute is_struct(operation_error)

      assert operation_error == %{
               cassette: "opsmaru_incus",
               operation_id: "incus_instance_exec",
               source: "opsmaru_incus",
               operation_error: error
             }
    end

    test "an executor error not matching default is invalid_output", %{index: index} do
      respond = fn _call, _input -> {:error, %{"reason" => "nope", "operation_id" => "op-3"}} end

      assert {:error, %Error{kind: :invalid_output, dispatched: true} = error} =
               execute(index, "opsmaru_incus", "incus_instance_exec", exec_input(),
                 executors: executors(respond)
               )

      assert error.details == %{identity: %{"operation_id" => "op-3"}}
    end

    test "without a default schema, any JSON error map is an operation error", %{index: index} do
      respond = fn _call, _input -> {:error, %{"anything" => [1, "two"]}} end

      assert {:error, %{operation_error: %{"anything" => [1, "two"]}}} =
               execute(index, "macus", "list_instances", %{}, executors: executors(respond))
    end

    test "a result violating the 200 schema is invalid_output with only identity values", %{
      index: index
    } do
      result = %{
        "operation_id" => "op-42",
        "status" => "Running",
        "resource" => "secret-resource",
        "extra" => true
      }

      respond = fn _call, _input ->
        {:ok, Map.delete(result, "status") |> Map.put("status", 7)}
      end

      log =
        capture_log(fn ->
          assert {:error, %Error{kind: :invalid_output, dispatched: true} = error} =
                   execute(index, "opsmaru_incus", "incus_image_delete", delete_input(),
                     executors: executors(respond)
                   )

          assert error.details == %{identity: %{"operation_id" => "op-42", "status" => 7}}
          assert error.message =~ "reconcile"
          refute inspect(error) =~ "secret-resource"
        end)

      refute log =~ "secret-resource"
    end

    test "identity values are kept only when they are short top-level scalars", %{index: index} do
      for {value, kept} <- [
            {"op-1", true},
            {String.duplicate("o", 256), true},
            {String.duplicate("o", 257), false},
            {12, true},
            {true, true},
            {1.5, false},
            {%{"nested" => "x"}, false},
            {["x"], false},
            {nil, false}
          ] do
        respond = fn _call, _input -> {:ok, %{"operation_id" => value}} end

        assert {:error, %Error{kind: :invalid_output} = error} =
                 execute(index, "opsmaru_incus", "incus_image_delete", delete_input(),
                   executors: executors(respond)
                 )

        assert Map.has_key?(error.details.identity, "operation_id") == kept, inspect(value)
      end
    end

    test "an unexpected return value is invalid_output", %{index: index} do
      for returned <- [
            :ok,
            nil,
            {:ok, "done"},
            {:ok, [1]},
            {:error, "failed"},
            {:ok, %{"pid" => self()}},
            {:ok, %{operation_id: "op-1", exit_code: 0}},
            {:ok, exec_result(), :extra},
            {:ok, URI.parse("http://example.com")}
          ] do
        respond = fn _call, _input -> returned end

        assert {:error, %Error{kind: :invalid_output, dispatched: true}} =
                 execute(index, "opsmaru_incus", "incus_instance_exec", exec_input(),
                   executors: executors(respond)
                 ),
               inspect(returned)
      end
    end

    test "a non-JSON result still carries its identity values", %{index: index} do
      respond = fn _call, _input -> {:ok, %{"operation_id" => "op-5", "pid" => self()}} end

      assert {:error,
              %Error{kind: :invalid_output, details: %{identity: %{"operation_id" => "op-5"}}}} =
               execute(index, "opsmaru_incus", "incus_instance_exec", exec_input(),
                 executors: executors(respond)
               )
    end
  end

  describe "errors" do
    test "every error says whether the operation was dispatched", %{index: index} do
      cases = [
        {:not_found, false, fn -> execute(index, "macus", "missing", %{}) end},
        {:no_executor, false,
         fn -> execute(index, "macus", "list_instances", %{}, executors: %{}) end},
        {:invalid_input, false, fn -> execute(index, "macus", "list_instances", "x") end},
        {:confirmation_required, false,
         fn ->
           execute(index, "opsmaru_incus", "incus_image_delete", %{"fingerprint" => @fingerprint})
         end},
        {:dispatch_failed, true,
         fn ->
           execute(index, "macus", "list_instances", %{},
             executors: executors(fn _c, _i -> raise "x" end)
           )
         end},
        {:invalid_output, true,
         fn ->
           execute(index, "macus", "list_instances", %{},
             executors: executors(fn _c, _i -> :ok end)
           )
         end}
      ]

      for {kind, dispatched, run} <- cases do
        assert {:error, %Error{kind: ^kind, dispatched: ^dispatched} = error} = run.()
        assert byte_size(error.message) <= 256
        assert error.message =~ "reconcile" == dispatched
      end
    end

    test "a not-run failure and a may-have-run failure are told apart", %{index: index} do
      {:error, not_run} =
        execute(index, "opsmaru_incus", "incus_instance_exec", %{"instance" => "web-1"})

      {:error, ran} =
        execute(index, "opsmaru_incus", "incus_instance_exec", exec_input(),
          executors: executors(fn _c, _i -> {:ok, %{"bad" => true}} end)
        )

      assert %Error{kind: :invalid_input, dispatched: false} = not_run
      assert %Error{kind: :invalid_output, dispatched: true} = ran
      assert ran.message =~ "may have taken effect"
    end

    test "arguments are validated", %{index: index} do
      assert_raise ArgumentError, ~r/:scopes is required/, fn ->
        Tama.Dex.execute(index, "macus", "list_instances", %{}, executors: %{})
      end

      assert_raise ArgumentError, ~r/:executors is required/, fn ->
        Tama.Dex.execute(index, "macus", "list_instances", %{}, scopes: [])
      end

      assert_raise ArgumentError, ~r/:executors must be a map/, fn ->
        Tama.Dex.execute(index, "macus", "list_instances", %{}, scopes: [], executors: [])
      end

      assert_raise ArgumentError, fn ->
        Tama.Dex.execute(index, "Macus", "x", %{}, scopes: [], executors: %{})
      end

      assert_raise ArgumentError, fn ->
        Tama.Dex.execute(index, "macus", :x, %{}, scopes: [], executors: %{})
      end
    end
  end

  describe "retention" do
    test "inputs and results never appear in logs or telemetry", %{index: index} do
      events = for name <- [:start, :stop, :exception], do: [:tama_dex, :execute, name]
      ref = :telemetry_test.attach_event_handlers(self(), events)

      input = %{"instance" => "secret-instance", "command" => ["secret-command"]}
      result = exec_result(%{"stdout" => "secret-stdout"})

      log =
        capture_log(fn ->
          {:ok, _response} =
            execute(index, "opsmaru_incus", "incus_instance_exec", input,
              executors: executors(fn _c, _i -> {:ok, result} end)
            )

          {:error, _error} =
            execute(index, "opsmaru_incus", "incus_instance_exec", input,
              executors: executors(fn _c, _i -> {:ok, %{"stdout" => "secret-stdout"}} end)
            )
        end)

      refute log =~ "secret"

      assert_received {[:tama_dex, :execute, :start], ^ref, _measurements, start}

      assert Map.delete(start, :telemetry_span_context) ==
               %{cassette: "opsmaru_incus", operation_id: "incus_instance_exec"}

      assert_received {[:tama_dex, :execute, :stop], ^ref, %{duration: _}, stop}

      assert Map.delete(stop, :telemetry_span_context) == %{
               cassette: "opsmaru_incus",
               operation_id: "incus_instance_exec",
               source: "opsmaru_incus",
               outcome: :ok
             }

      assert_received {[:tama_dex, :execute, :stop], ^ref, _measurements,
                       %{outcome: :invalid_output} = failed}

      refute inspect(failed) =~ "secret"
    end

    test "an operation error's outcome is reported without its content", %{index: index} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:tama_dex, :execute, :stop]])

      {:error, %{operation_error: _error}} =
        execute(index, "macus", "list_instances", %{},
          executors: executors(fn _c, _i -> {:error, %{"secret" => "x"}} end)
        )

      assert_received {[:tama_dex, :execute, :stop], ^ref, _measurements, metadata}
      assert metadata.outcome == :operation_error
      refute inspect(metadata) =~ "secret"
    end
  end

  describe "host adapters" do
    test "a producer runs behind a host adapter, compiled without tama_dex", %{index: index} do
      {:ok, _loaded} = Tama.Dex.load(index, FakeProducer.document(), cassette: "acme")
      executors = %{"acme" => {AcmeAdapter, authorizer: AcmeAuthorizer}}

      assert {:ok, %{result: %{"id" => "w1", "name" => "Widget w1"}}} =
               Tama.Dex.execute(index, "acme", "acme_widget_get", %{"id" => "w1"},
                 scopes: ["acme.read"],
                 executors: executors,
                 context: %{allowed: true}
               )

      assert {:error, %{operation_error: %{"reason" => "forbidden"}}} =
               Tama.Dex.execute(index, "acme", "acme_widget_get", %{"id" => "w1"},
                 scopes: ["acme.read"],
                 executors: executors,
                 context: %{allowed: false}
               )

      # Read from ebin: under cover, :code.which/1 names no file.
      beam = Path.join([:code.lib_dir(:tama_dex), "ebin", "#{FakeProducer}.beam"])

      {:ok, {_module, [imports: imports]}} =
        :beam_lib.chunks(String.to_charlist(beam), [:imports])

      refute Enum.any?(imports, fn {module, _function, _arity} ->
               String.starts_with?(Atom.to_string(module), "Elixir.Tama.Dex.")
             end)
    end
  end
end
