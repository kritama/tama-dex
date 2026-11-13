defmodule Tama.Dex.Document do
  @moduledoc """
  A validated `tama-operations/1` document, as returned by
  `Tama.Dex.Profile.validate/1`.

  - `source` is the document's `x-tama-source`, the ID executors are
    registered under.
  - `title` and `version` come from `info`.
  - `digest` is the lowercase hex SHA-256 of `canonical_json`.
  - `canonical_json` is the whole document as canonical JSON: object keys
    sorted by their UTF-8 bytes, with no insignificant whitespace.
  - `operations` are the normalized operations, ordered by `operationId`.
  """

  alias Tama.Dex.Operation

  @type t :: %__MODULE__{
          profile: String.t(),
          source: String.t(),
          title: String.t(),
          version: String.t(),
          digest: String.t(),
          canonical_json: binary(),
          operations: [Operation.t()]
        }

  @enforce_keys [:profile, :source, :title, :version, :digest, :canonical_json, :operations]
  defstruct @enforce_keys
end
