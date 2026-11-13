defmodule Tama.Dex.Executor do
  @moduledoc """
  The behaviour a host implements to run the operations of one source.

  tama-dex never performs an operation itself. After `Tama.Dex.execute/5`
  has checked the caller's scopes, the confirmation field and the input
  schema, it calls the executor registered for the operation's source,
  exactly once, in the caller's process and with no deadline of its own.

  Executors are host adapter modules. A producer library publishes its
  profile document as data and keeps its own run function; it needs no
  tama_dex dependency. The host's adapter translates the call, adding
  host-only arguments such as an authorization module or the verified
  caller:

      defmodule MyHost.IncusExecutor do
        @behaviour Tama.Dex.Executor

        @impl Tama.Dex.Executor
        def execute(%Tama.Dex.Call{} = call, input) do
          OpsmaruIncus.run(call.operation_id, input,
            authorizer: Keyword.fetch!(call.opts, :authorizer),
            caller: call.context,
            scopes: call.scopes
          )
        end
      end

  ## Registration

  Hosts pass executors to `Tama.Dex.execute/5` as a map from source ID to a
  module, or `{module, opts}`:

      %{"opsmaru_incus" => {MyHost.IncusExecutor, authorizer: MyHost.Authorizer}}

  A missing entry, or a module that isn't loaded or doesn't export
  `execute/2`, fails with `:no_executor` before dispatch. One registration
  serves every cassette carrying that source.

  ## Results

  Return `{:ok, result}` or `{:error, error}`, each a JSON object: a map with
  string keys and JSON values, as decoded JSON. `result` must match the
  operation's `200` schema, and `error` its `default` schema when one is
  declared. Anything else is reported as `:invalid_output`.
  """

  alias Tama.Dex.Call

  @doc """
  Runs one validated call. `input` has already passed the operation's input
  schema, and is passed unaltered.
  """
  @callback execute(call :: Call.t(), input :: map()) :: {:ok, map()} | {:error, map()}
end
