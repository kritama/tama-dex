defmodule Tama.Dex.Profile.Issue do
  @moduledoc """
  A defect found by `Tama.Dex.Profile.validate/1`.

  - `pointer` is the JSON Pointer (RFC 6901) of the offending value, or of
    where a missing value belongs. `""` is the whole document.
  - `code` is a stable atom. Match on it, not on the message.
  - `message` is human-readable text of at most 256 bytes.

  ## Codes

  | Code | Meaning |
  |---|---|
  | `:invalid_document` | The document isn't a JSON object. |
  | `:invalid_json` | A value isn't JSON data (for example an atom, a tuple or a non-string key). |
  | `:unsupported_profile` | `x-tama-profile` is missing or isn't `tama-operations/1`. |
  | `:document_too_large` | The serialized document is over 4 MiB. |
  | `:too_many_operations` | The document holds more than 1024 operations. |
  | `:missing_field` | A required field is absent. |
  | `:invalid_field` | A field has the wrong type or value. |
  | `:unknown_field` | A field the profile doesn't allow is present. |
  | `:unknown_extension` | An `x-tama-*` key this profile version doesn't define is present. |
  | `:invalid_path` | A path isn't `/operations/{operationId}`. |
  | `:operation_id_mismatch` | The path suffix isn't the operation's `operationId`. |
  | `:duplicate_operation_id` | An `operationId` appears more than once in the document. |
  | `:invalid_input_schema` | The request body schema isn't an object schema. |
  | `:invalid_confirmation` | `x-tama-confirmation.field` isn't a required top-level string property of the input schema. |
  | `:invalid_identity` | An `x-tama-identity` name isn't a top-level property of the `200` or `default` schema. |
  | `:extensions_too_large` | An operation's other `x-` extensions are over 16 KiB. |
  | `:external_reference` | A `$ref` points outside the document. |
  | `:invalid_reference` | A `$ref` isn't a pointer into `#/components/schemas/`, or a schema declares `$id`. |
  | `:unresolved_reference` | A `$ref` points at nothing. |
  | `:schema_too_large` | A request or response schema, with the components it references, is over 256 KiB. |
  | `:schema_compile_failed` | A request or response schema doesn't compile as JSON Schema 2020-12. |
  """

  @type code ::
          :invalid_document
          | :invalid_json
          | :unsupported_profile
          | :document_too_large
          | :too_many_operations
          | :missing_field
          | :invalid_field
          | :unknown_field
          | :unknown_extension
          | :invalid_path
          | :operation_id_mismatch
          | :duplicate_operation_id
          | :invalid_input_schema
          | :invalid_confirmation
          | :invalid_identity
          | :extensions_too_large
          | :external_reference
          | :invalid_reference
          | :unresolved_reference
          | :schema_too_large
          | :schema_compile_failed

  @type t :: %__MODULE__{pointer: String.t(), code: code(), message: String.t()}

  @enforce_keys [:pointer, :code, :message]
  defstruct [:pointer, :code, :message]

  @max_message_bytes 256

  @doc false
  @spec new(String.t(), code(), String.t()) :: t()
  def new(pointer, code, message) do
    %__MODULE__{pointer: pointer, code: code, message: bound(message)}
  end

  defp bound(message) when byte_size(message) <= @max_message_bytes, do: message

  defp bound(message) do
    prefix = binary_part(message, 0, @max_message_bytes - 3)

    valid =
      case :unicode.characters_to_binary(prefix) do
        {:incomplete, valid, _rest} -> valid
        valid when is_binary(valid) -> valid
      end

    valid <> "..."
  end
end
