defmodule Tama.Dex.Execute do
  @moduledoc false

  # Validated execute, run in the caller's process.
  #
  # Checks run in order and stop at the first failure: lookup (visibility),
  # executor, input shape, confirmation, input schema. Only then is the
  # executor called, exactly once and with no deadline. Its return value is
  # checked against the declared result schemas. Inputs and results are
  # never stored, logged or sent in telemetry.

  alias Tama.Dex.Call
  alias Tama.Dex.Error
  alias Tama.Dex.Index
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.Issues
  alias Tama.Dex.JSON
  alias Tama.Dex.Search

  @max_input_bytes 1024 * 1024
  @max_identity_bytes 256

  @type outcome :: Tama.Dex.execute_result()

  @doc "Runs a validated execute. Returns the outcome and the source (or `nil`)."
  @spec run(Index.t(), String.t(), String.t(), term(), map()) :: {outcome(), String.t() | nil}
  def run(index, cassette, operation_id, input, options) do
    case Index.read(index, &lookup(&1, cassette, operation_id, options.scopes)) do
      nil ->
        {{:error, Error.new(:not_found, "No such operation is available to this caller.")}, nil}

      operation ->
        {dispatch(index, operation, input, options), operation.source}
    end
  end

  defp dispatch(index, operation, input, options) do
    with {:ok, executor} <- executor(options.executors, operation.source),
         :ok <- check_shape(input),
         :ok <- check_confirmation(operation.confirmation, input),
         :ok <- check_input(index, operation, input) do
      call = %Call{
        cassette: operation.cassette,
        source: operation.source,
        operation_id: operation.operation_id,
        scopes: options.scopes,
        context: options.context,
        opts: elem(executor, 1)
      }

      call
      |> invoke(elem(executor, 0), input)
      |> check_result(index, operation)
    end
  end

  # Lookup

  @doc false
  def lookup(conn, cassette, operation_id, scopes) do
    case SQL.query!(
           conn,
           """
           SELECT o.cassette, o.source, o.operation_id, o.confirmation, o.identity,
                  o.input_schema, o.input_schema_digest, o.success_schema, o.success_schema_digest,
                  o.error_schema, o.error_schema_digest
           FROM operations o
           WHERE o.cassette = ? AND o.operation_id = ? AND #{Search.visible_clause()}
           """,
           [cassette, operation_id, Jason.encode!(scopes)]
         ) do
      [[cassette, source, id, confirmation, identity | schemas]] ->
        [input, input_digest, success, success_digest, error, error_digest] = schemas

        %{
          cassette: cassette,
          source: source,
          operation_id: id,
          confirmation: confirmation && Jason.decode!(confirmation),
          identity: if(identity, do: Jason.decode!(identity), else: []),
          input_schema: {input_digest, input},
          success_schema: {success_digest, success},
          error_schema: error && {error_digest, error}
        }

      [] ->
        nil
    end
  end

  # Executor

  defp executor(executors, source) do
    with {:ok, registration} <- Map.fetch(executors, source),
         {module, opts} when is_atom(module) and is_list(opts) <- registration(registration),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :execute, 2) do
      {:ok, {module, opts}}
    else
      _missing ->
        {:error,
         Error.new(:no_executor, "No executor is registered for source #{source}.", %{
           source: source
         })}
    end
  end

  defp registration({module, opts}), do: {module, opts}
  defp registration(module), do: {module, []}

  # Input shape

  defp check_shape(input) do
    if is_map(input) and JSON.data?(input) and byte_size(Jason.encode!(input)) <= @max_input_bytes do
      :ok
    else
      {:error,
       Error.new(
         :invalid_input,
         "The input must be a JSON object, with string keys and JSON values, of at most 1 MiB."
       )}
    end
  end

  # Confirmation

  defp check_confirmation(nil, _input), do: :ok

  defp check_confirmation(%{"field" => field, "description" => description}, input) do
    case Map.get(input, field) do
      value when value in [nil, ""] ->
        confirmation_required(field, description)

      value when is_binary(value) ->
        if String.trim(value) == "", do: confirmation_required(field, description), else: :ok

      _other ->
        :ok
    end
  end

  defp confirmation_required(field, description) do
    {:error,
     Error.new(
       :confirmation_required,
       "This operation needs confirmation: send #{field} with #{description}.",
       %{field: field, description: description}
     )}
  end

  # Input schema

  defp check_input(index, operation, input) do
    case validate(index, operation.input_schema, input) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error,
         Error.new(
           :invalid_input,
           "The input does not match the operation's input schema.",
           Issues.from_errors(errors)
         )}
    end
  end

  defp validate(index, {digest, text}, value) do
    case Index.compiled_schema(Index.schema_cache(index), digest, text) do
      {:ok, compiled} -> JSONSchex.validate(compiled, value)
      {:error, _error} -> raise "a stored operation schema does not compile"
    end
  end

  # Dispatch

  defp invoke(call, module, input) do
    {:returned, module.execute(call, input)}
  rescue
    _exception -> {:failed, :error}
  catch
    :exit, _reason -> {:failed, :exit}
    :throw, _value -> {:failed, :throw}
  end

  # Result

  defp check_result({:failed, kind}, _index, _operation) do
    {:error, Error.new(:dispatch_failed, "The executor failed.", %{exception_kind: kind})}
  end

  defp check_result({:returned, {:ok, result}}, index, operation) when is_map(result) do
    with :ok <- check_returned(result, operation),
         :ok <- check_schema(index, operation.success_schema, result, operation) do
      {:ok,
       %{
         cassette: operation.cassette,
         operation_id: operation.operation_id,
         source: operation.source,
         result: result
       }}
    end
  end

  defp check_result({:returned, {:error, error}}, index, operation) when is_map(error) do
    with :ok <- check_returned(error, operation),
         :ok <- check_schema(index, operation.error_schema, error, operation) do
      {:error,
       %{
         cassette: operation.cassette,
         operation_id: operation.operation_id,
         source: operation.source,
         operation_error: error
       }}
    end
  end

  defp check_result({:returned, _other}, _index, _operation) do
    invalid_output("The executor returned neither {:ok, map} nor {:error, map}.", %{})
  end

  defp check_returned(map, operation) do
    if JSON.data?(map),
      do: :ok,
      else:
        invalid_output("The executor's result is not a JSON object.", identity(map, operation))
  end

  defp check_schema(_index, nil, _value, _operation), do: :ok

  defp check_schema(index, schema, value, operation) do
    case validate(index, schema, value) do
      :ok ->
        :ok

      {:error, _errors} ->
        invalid_output(
          "The executor's result does not match the operation's declared result.",
          identity(value, operation)
        )
    end
  end

  defp invalid_output(message, identity) do
    {:error, Error.new(:invalid_output, message, %{identity: identity})}
  end

  # The declared identity values: top-level strings, integers and booleans
  # of at most 256 bytes, so a caller can reconcile the operation.
  defp identity(map, operation) do
    for name <- operation.identity,
        {:ok, value} <- [Map.fetch(map, name)],
        identity_value?(value),
        into: %{} do
      {name, value}
    end
  end

  defp identity_value?(value) when is_binary(value),
    do: byte_size(value) <= @max_identity_bytes and String.valid?(value)

  defp identity_value?(value) when is_integer(value) or is_boolean(value), do: true
  defp identity_value?(_value), do: false
end
