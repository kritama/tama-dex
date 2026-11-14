defmodule Tama.Dex.Error do
  @moduledoc """
  An error produced by tama-dex during `Tama.Dex.execute/5`.

  `dispatched` says whether the executor was called:

  - `false`: the operation did not run. Kinds `:not_found`, `:not_ready`,
    `:no_executor`, `:invalid_input` and `:confirmation_required`.
  - `true`: the operation may have taken effect, and must be reconciled
    rather than retried. Kinds `:dispatch_failed` and `:invalid_output`.

  An executor's own valid error is not a `Tama.Dex.Error`. `execute/5`
  returns it as `{:error, %{cassette, operation_id, source, operation_error}}`,
  so match `%Tama.Dex.Error{}` first.

  `message` is at most 256 bytes. `details` depends on the kind:

  | Kind | Details |
  |---|---|
  | `:no_executor` | `%{source: source}` |
  | `:invalid_input` | `%{issues: [%{pointer, message}], issues_truncated: boolean}` (at most 16 issues), or `%{}` when the input isn't a JSON object within 1 MiB |
  | `:confirmation_required` | `%{field: field, description: description}` |
  | `:dispatch_failed` | `%{exception_kind: :error \\| :exit \\| :throw}` |
  | `:invalid_output` | `%{identity: %{name => value}}`, the declared `x-tama-identity` values found in the result |

  Errors never carry input values or result content, apart from those
  identity values.
  """

  alias Tama.Dex.Text

  @type kind ::
          :not_found
          | :not_ready
          | :no_executor
          | :invalid_input
          | :confirmation_required
          | :dispatch_failed
          | :invalid_output

  @type t :: %__MODULE__{
          kind: kind(),
          dispatched: boolean(),
          message: String.t(),
          details: map()
        }

  @enforce_keys [:kind, :dispatched, :message]
  defstruct [:kind, :dispatched, :message, details: %{}]

  @dispatched [:dispatch_failed, :invalid_output]
  @reconcile "The operation may have taken effect: reconcile its state rather than retrying."

  @doc false
  @spec new(kind(), String.t(), map()) :: t()
  def new(kind, message, details \\ %{}) do
    dispatched = kind in @dispatched
    message = if dispatched, do: message <> " " <> @reconcile, else: message

    %__MODULE__{
      kind: kind,
      dispatched: dispatched,
      message: Text.bound(message, 256),
      details: details
    }
  end
end
