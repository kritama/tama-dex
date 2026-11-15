defmodule Tama.Dex.TelemetryTest do
  use ExUnit.Case, async: true

  import Tama.Dex.TestSupport.Cassettes
  import Tama.Dex.TestSupport.Documents
  import Tama.Dex.TestSupport.Telemetry

  alias Tama.Dex.Index
  alias Tama.Dex.TestSupport.CountingExecutor

  @moduletag :tmp_dir

  @load_keys [:cassette, :source, :changed, :operations, :result, :telemetry_span_context]

  defp start_index!, do: start_supervised!({Index, path: :memory}, id: make_ref())

  defp stopped_index! do
    index = start_supervised!({Index, path: :memory}, id: :stopped)
    :ok = stop_supervised(:stopped)
    index
  end

  defp spans(name), do: for(event <- [:start, :stop, :exception], do: [:tama_dex, name, event])

  defp secret_document do
    "secret_source"
    |> document(["secret_source_op"])
    |> put_in(["info", "description"], "secret-description")
  end

  defp assert_sanitized(metadata) do
    assert is_atom(metadata.reason)
    assert Enum.all?(metadata.stacktrace, &match?({_m, _f, arity, _l} when is_integer(arity), &1))
    refute inspect(metadata) =~ "secret"
  end

  describe "load" do
    test "metadata names the cassette and counts, never the document" do
      index = start_index!()
      ref = attach_local(spans(:load))

      {:ok, _loaded} = Tama.Dex.load(index, secret_document(), cassette: "probe")

      assert_received {[:tama_dex, :load, :start], ^ref, %{monotonic_time: _, system_time: _},
                       %{cassette: "probe", telemetry_span_context: context} = start}

      assert map_size(start) == 2

      assert_received {[:tama_dex, :load, :stop], ^ref, %{duration: _, monotonic_time: _},
                       %{telemetry_span_context: ^context} = stop}

      assert Map.delete(stop, :telemetry_span_context) == %{
               cassette: "probe",
               source: "secret_source",
               changed: true,
               operations: 1,
               result: :ok
             }

      invalid = put_in(secret_document(), ["openapi"], "secret-version")
      {:error, {:invalid_document, _issues}} = Tama.Dex.load(index, invalid, cassette: "probe")

      assert_received {[:tama_dex, :load, :stop], ^ref, _measurements,
                       %{result: :invalid_document} = failed}

      assert Map.keys(failed) -- @load_keys == []
      refute inspect(failed) =~ "secret"
    end
  end

  describe "import" do
    test "a rejected cassette reports its error kind, never its path", %{tmp_dir: tmp_dir} do
      index = start_index!()

      built =
        build!(tmp_dir, "secret.tama-cassette", [secret_document()], name: "probe", version: "1")

      tamper!(built.path, "UPDATE cassette_documents SET document = document || ' '")

      ref = :telemetry_test.attach_event_handlers(self(), spans(:import))

      assert {:error, {:document_digest_mismatch, "secret_source"}} =
               Tama.Dex.import(index, built.path, as: "telemetry_rejected")

      # The import runs in the index's writer, so match this test's cassette.
      assert_receive {[:tama_dex, :import, :stop], ^ref, %{duration: _},
                      %{cassette: "telemetry_rejected"} = metadata}

      :telemetry.detach(ref)

      assert Map.delete(metadata, :telemetry_span_context) ==
               %{cassette: "telemetry_rejected", result: :document_digest_mismatch}

      refute inspect(metadata) =~ tmp_dir
    end
  end

  describe "exceptions" do
    test "carry the error's module and argument-free stacktraces" do
      ref = attach_local(spans(:probe))

      assert_raise FunctionClauseError, fn ->
        Tama.Dex.Telemetry.span([:tama_dex, :probe], %{}, fn ->
          only_ok(opaque("secret-argument"))
        end)
      end

      assert_received {[:tama_dex, :probe, :exception], ^ref, %{duration: _, monotonic_time: _},
                       %{kind: :error, reason: FunctionClauseError} = metadata}

      assert [{__MODULE__, :only_ok, 1, _location} | _rest] = metadata.stacktrace
      assert_sanitized(metadata)

      assert_raise KeyError, ~r/secret-key/, fn ->
        Tama.Dex.Telemetry.span([:tama_dex, :probe], %{}, fn ->
          Map.fetch!(opaque(%{}), "secret-key")
        end)
      end

      assert_received {[:tama_dex, :probe, :exception], ^ref, _measurements,
                       %{reason: KeyError} = metadata}

      assert_sanitized(metadata)

      assert catch_throw(
               Tama.Dex.Telemetry.span([:tama_dex, :probe], %{}, fn -> throw("secret-throw") end)
             ) == "secret-throw"

      assert_received {[:tama_dex, :probe, :exception], ^ref, _measurements,
                       %{kind: :throw, reason: :unknown} = metadata}

      assert_sanitized(metadata)
    end

    test "from load, search and execute hold no caller data" do
      index = stopped_index!()
      ref = attach_local(spans(:load) ++ spans(:search) ++ spans(:execute))

      catch_exit(Tama.Dex.load(index, secret_document(), cassette: "probe"))
      assert_received {[:tama_dex, :load, :exception], ^ref, _measurements, load}
      assert load.cassette == "probe"
      assert_sanitized(load)

      catch_exit(Tama.Dex.search(index, "secret query", scopes: ["test.read"]))
      assert_received {[:tama_dex, :search, :exception], ^ref, _measurements, search}
      assert search.query_length == 12
      assert_sanitized(search)

      catch_exit(
        Tama.Dex.execute(index, "probe", "secret_source_op", %{"secret" => "secret-input"},
          scopes: ["test.read"],
          executors: %{"secret_source" => {CountingExecutor, test: self()}}
        )
      )

      assert_received {[:tama_dex, :execute, :exception], ^ref, _measurements, execute}
      assert execute.operation_id == "secret_source_op"
      # The operation ID is the caller's address, not data it sent.
      assert_sanitized(Map.delete(execute, :operation_id))
    end
  end

  test "status events carry only the status and the index" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:tama_dex, :index, :status]])
    index = start_index!()

    {:ok, _loaded} = Tama.Dex.load(index, secret_document(), cassette: "probe")

    assert_receive {[:tama_dex, :index, :status], ^ref, %{},
                    %{index: ^index, status: :ready} = metadata}

    :telemetry.detach(ref)

    assert Map.keys(metadata) |> Enum.sort() == [:index, :status]
  end

  defp only_ok(:ok), do: :ok

  # Hides a value's type from the compiler, so a call bound to fail compiles
  # without a warning.
  defp opaque(value), do: Process.get(:tama_dex_never_set, value)
end
