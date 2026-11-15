defmodule Tama.Dex.Operation do
  @moduledoc """
  One normalized operation of a `Tama.Dex.Document`.

  - `scopes`: a caller needs every one of them to run the operation.
  - `confirmation`: `%{field: name, description: text}` or `nil`.
  - `bounds`: the informational `x-tama-bounds` map, or `%{}`.
  - `identity`: the `x-tama-identity` names, or `[]`.
  - `extensions`: the operation's other `x-` extensions, kept as opaque
    metadata. They are never used for search ranking or authorization.
  - `fields`: the input schema's top-level properties, as
    `%{name: name, description: text | nil}` ordered by name.
  - `input_schema`, `success_schema` and `error_schema`: the request, `200`
    and `default` schemas, each bundled to stand alone. Any components a
    schema references are carried under its `$defs`. `error_schema` is `nil`
    when the operation declares no `default` response.
  """

  @type confirmation :: %{field: String.t(), description: String.t()}
  @type field :: %{name: String.t(), description: String.t() | nil}

  @type t :: %__MODULE__{
          source: String.t(),
          operation_id: String.t(),
          summary: String.t(),
          description: String.t(),
          tags: [String.t()],
          deprecated: boolean(),
          scopes: [String.t()],
          destructive: boolean(),
          confirmation: confirmation() | nil,
          bounds: %{optional(String.t()) => non_neg_integer()},
          identity: [String.t()],
          extensions: %{optional(String.t()) => term()},
          fields: [field()],
          input_schema: map(),
          success_schema: map(),
          error_schema: map() | nil
        }

  @enforce_keys [
    :source,
    :operation_id,
    :summary,
    :description,
    :scopes,
    :destructive,
    :input_schema,
    :success_schema
  ]
  defstruct @enforce_keys ++
              [
                tags: [],
                deprecated: false,
                confirmation: nil,
                bounds: %{},
                identity: [],
                extensions: %{},
                fields: [],
                error_schema: nil
              ]
end
