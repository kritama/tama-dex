defmodule Tama.Dex.Call do
  @moduledoc """
  A validated call handed to a `Tama.Dex.Executor`.

  - `cassette`, `source` and `operation_id` name the operation.
  - `scopes` are exactly the verified scopes tama-dex checked, in the order
    the caller gave them, so the executor re-checks what tama-dex saw.
  - `context` is the host term passed to `Tama.Dex.execute/5` (for the MCP
    handlers, the caller).
  - `opts` are the options given at registration, `[]` for a bare module.
  """

  @type t :: %__MODULE__{
          cassette: String.t(),
          source: String.t(),
          operation_id: String.t(),
          scopes: [String.t()],
          context: term(),
          opts: keyword()
        }

  @enforce_keys [:cassette, :source, :operation_id, :scopes]
  defstruct [:cassette, :source, :operation_id, :scopes, context: nil, opts: []]
end
