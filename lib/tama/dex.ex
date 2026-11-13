defmodule Tama.Dex do
  @moduledoc """
  Index, search and validated execute for operation documents in the Tama
  operations profile of OpenAPI 3.1 (`tama-operations/1`).

  tama-dex is a library. Loading or starting the `:tama_dex` application
  starts no process, opens no database, creates no file and fetches nothing.
  A host starts `Tama.Dex.Index` under its own supervisor, with an explicit
  database path, and passes the index into every call.

  The profile is described in `docs/tama-operations-profile.md`.
  """
end
