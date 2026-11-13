defmodule Tama.Dex do
  @moduledoc """
  Index, search and validated execute for operation documents in the Tama
  operations profile of OpenAPI 3.1 (`tama-operations/1`).

  tama-dex is a library. Loading or starting the `:tama_dex` application
  starts no process, opens no database, creates no file and fetches nothing.
  A host starts `Tama.Dex.Index` under its own supervisor, with an explicit
  database path, and passes the index into every call.

  The profile is described in `docs/tama-operations-profile.md`.

  ## Cassettes

  Every source in an index belongs to one cassette, its namespace. A
  cassette name matches `^[a-z][a-z0-9_]{0,63}$`, and operations are
  addressed by cassette and `operationId`, so two cassettes may carry the
  same operation name. A cassette is either local, built by `load/3` from
  documents the host holds, or imported from a cassette file. A name belongs
  to one kind.
  """

  alias Tama.Dex.Execute
  alias Tama.Dex.Index
  alias Tama.Dex.Index.Store
  alias Tama.Dex.Profile
  alias Tama.Dex.Search

  @cassette_name ~r/^[a-z][a-z0-9_]{0,63}$/

  @type cassette :: String.t()

  @type execute_result ::
          {:ok,
           %{cassette: cassette(), operation_id: String.t(), source: String.t(), result: map()}}
          | {:error,
             %{
               cassette: cassette(),
               operation_id: String.t(),
               source: String.t(),
               operation_error: map()
             }}
          | {:error, Tama.Dex.Error.t()}

  @type load_error ::
          {:invalid_document, [Profile.Issue.t()]}
          | :cassette_conflict
          | {:duplicate_operation, [%{source: String.t(), operation_ids: [String.t()]}]}

  @doc """
  Validates a profile document and installs it as one source of the local
  cassette named by the required `:cassette` option.

  The document is validated in full first, under the index's limits. The
  source's previous entries are then replaced in one transaction, so readers
  see either the old set or the new one. Loading a document whose
  canonical-JSON digest is already installed for that source changes
  nothing and reports `changed: false`.

  Returns `{:ok, %{cassette, source, operations, changed}}`, where
  `operations` is the number of operations in the document, or one of:

  - `{:error, {:invalid_document, issues}}` when validation fails;
  - `{:error, :cassette_conflict}` when the name belongs to an imported
    cassette;
  - `{:error, {:duplicate_operation, conflicts}}` when another source of the
    same cassette owns some of the document's `operationId`s, with each
    owning source and its conflicting IDs.

  A failed load changes nothing. Raises `ArgumentError` when `:cassette` is
  missing or not a valid cassette name.
  """
  @spec load(Index.t(), term(), keyword()) ::
          {:ok,
           %{
             cassette: cassette(),
             source: String.t(),
             operations: non_neg_integer(),
             changed: boolean()
           }}
          | {:error, load_error()}
  def load(index, document, opts) do
    cassette = cassette!(Keyword.get(opts, :cassette))

    :telemetry.span([:tama_dex, :load], %{cassette: cassette}, fn ->
      result =
        case Profile.validate(document, limits: Index.limits(index)) do
          {:ok, document} -> Index.write(index, &Store.load(&1, cassette, document))
          {:error, issues} -> {:error, {:invalid_document, issues}}
        end

      {result, load_metadata(cassette, result)}
    end)
  end

  defp load_metadata(cassette, {:ok, loaded}) do
    %{
      cassette: cassette,
      source: loaded.source,
      changed: loaded.changed,
      operations: loaded.operations,
      result: :ok
    }
  end

  defp load_metadata(cassette, {:error, reason}) do
    %{cassette: cassette, result: error_kind(reason)}
  end

  defp error_kind({kind, _detail}), do: kind
  defp error_kind(kind), do: kind

  @doc """
  Removes a cassette and every source and operation in it. Removing a
  cassette that isn't installed is a no-op. Raises `ArgumentError` for an
  invalid cassette name.
  """
  @spec unload(Index.t(), cassette()) :: :ok
  def unload(index, cassette) do
    cassette = cassette!(cassette)
    Index.write(index, &Store.unload(&1, cassette))
  end

  @doc """
  Lists the installed cassettes, ordered by name.

  Each is a map with `cassette`, `kind` (`:local` or `:imported`),
  `version`, `status`, `mode` (the import mode, `nil` for a local cassette),
  `digest` (the content digest of an imported cassette), `loaded_at` and
  `sources`. Each source has `source`, `title`, `version`, `profile`,
  `digest`, `operations` (a count) and `loaded_at`.
  """
  @spec cassettes(Index.t()) :: [map()]
  def cassettes(index), do: Index.read(index, &Store.cassettes/1)

  @doc """
  Searches the operations the caller may run, across every cassette in one
  ranking.

  `query` is caller text of at most 512 bytes, or `nil`. It is reduced to
  letter-and-digit terms, each matched as a prefix, all of which must match.
  Raw FTS5 syntax never reaches SQLite, so quotes, `NEAR`, `*`, `:`, `-` and
  `OR` in the text are inert. Text with no term lists operations in
  `(cassette, operation_id)` order.

  Matches are ranked by operation ID, then summary, tags, description and
  input fields. An `operationId` equal to the whole query ranks first, and
  ties are ordered by cassette, then `operationId`.

  ## Options

  - `:scopes` (required): the caller's verified scopes. Only operations
    whose every scope is among them are visible, and hidden operations never
    affect results, counts or flags.
  - `:limit`: 1 to 20, default 5.
  - `:cassette`, `:source`: only operations in that cassette or source.
  - `:tags`: only operations carrying every listed tag.
  - `:include_deprecated` (default `false`), `:include_destructive`
    (default `true`).
  - `:include_schemas` (default `true`): include each result's input schema.

  Raises `ArgumentError` for a missing `:scopes`, a query over 512 bytes, a
  limit outside 1 to 20, or another invalid option.

  Returns `{:ok, %{results: results, truncated: truncated}}`. Each result has
  `cassette`, `cassette_version`, `operation_id`, `source`, `summary`,
  `description` (cut to 1024 characters, with `description_truncated`),
  `tags`, `scopes`, `destructive`, `deprecated`, `confirmation`, `bounds` and
  `input_schema`. The encoded response stays within 64 KiB: input schemas
  are dropped from the lowest-ranked results first, each marked
  `schema_omitted: true`, and `truncated` is `true` when results themselves
  had to be cut.
  """
  @spec search(Index.t(), String.t() | nil, keyword()) ::
          {:ok, %{results: [map()], truncated: boolean()}}
  def search(index, query, opts) do
    options = Search.options!(query, opts)

    metadata = %{
      query_length: byte_size(options.text),
      cassette: options.cassette,
      limit: options.limit
    }

    :telemetry.span([:tama_dex, :search], metadata, fn ->
      response = Index.read(index, &Search.search(&1, options))

      {{:ok, response},
       Map.merge(metadata, %{results: length(response.results), truncated: response.truncated})}
    end)
  end

  @doc """
  Returns one operation the caller may run, addressed by cassette and
  `operationId`, in full: the search result fields with the whole
  description, plus `identity`, `success_schema`, `error_schema` and the
  operation's opaque `extensions`.

  An unknown cassette or operation, or one the caller's `:scopes` (required)
  don't allow, returns `{:error, :not_found}`.
  """
  @spec describe(Index.t(), cassette(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def describe(index, cassette, operation_id, opts) do
    cassette = cassette!(cassette)
    scopes = Search.scopes!(Keyword.get(opts, :scopes))

    operation_id = operation_id!(operation_id)

    case Index.read(index, &Search.describe(&1, cassette, operation_id, scopes)) do
      nil -> {:error, :not_found}
      operation -> {:ok, operation}
    end
  end

  @doc """
  Validates a call and hands it to the host's executor for the operation's
  source, exactly once.

  Runs in the caller's process. Each check stops at its first failure, and
  no executor is called unless all of them pass:

  1. The operation exists in `cassette` (and only there) and the caller's
     `:scopes` allow it, otherwise `:not_found`, which doesn't reveal
     whether a hidden operation or cassette exists.
  2. `:executors` has an entry for the operation's source, otherwise
     `:no_executor`. See `Tama.Dex.Executor`.
  3. `input` is a JSON object (a map with string keys and JSON values) of at
     most 1 MiB once encoded, otherwise `:invalid_input`.
  4. The operation's confirmation field, if it declares one, is present and
     not empty, otherwise `:confirmation_required`. This comes before the
     schema check, so a missing confirmation is never reported as invalid
     input.
  5. `input` matches the operation's input schema, otherwise
     `:invalid_input` with the failing JSON pointers.

  The executor is then called as `module.execute(call, input)` with a
  `Tama.Dex.Call`. tama-dex adds no deadline, and never retries: a raise,
  exit or throw returns `:dispatch_failed`. The return value must be
  `{:ok, result}` matching the `200` schema, or `{:error, error}` matching
  `default` when declared, each a JSON object; anything else returns
  `:invalid_output`, carrying only the operation's `x-tama-identity` values.

  ## Options

  - `:scopes` (required): the caller's verified scopes, passed to the
    executor as given.
  - `:executors` (required): `%{source => module | {module, opts}}`.
  - `:context`: any host term, passed to the executor as `call.context`.

  ## Returns

  - `{:ok, %{cassette, operation_id, source, result}}`;
  - `{:error, %{cassette, operation_id, source, operation_error}}`: the
    executor's own valid error, unchanged. The operation ran;
  - `{:error, %Tama.Dex.Error{}}`: a tama-dex error, whose `dispatched`
    says whether the executor was called. Match this form first.

  Inputs and results are never stored, logged or sent in telemetry.
  """
  @spec execute(Index.t(), cassette(), String.t(), term(), keyword()) :: execute_result()
  def execute(index, cassette, operation_id, input, opts) do
    options = %{
      cassette: cassette!(cassette),
      operation_id: operation_id!(operation_id),
      scopes: Search.scopes!(Keyword.get(opts, :scopes)),
      executors: executors!(Keyword.get(opts, :executors)),
      context: Keyword.get(opts, :context)
    }

    metadata = %{cassette: options.cassette, operation_id: options.operation_id}

    :telemetry.span([:tama_dex, :execute], metadata, fn ->
      {outcome, source} =
        Execute.run(index, options.cassette, options.operation_id, input, options)

      {outcome, Map.merge(metadata, %{source: source, outcome: outcome_kind(outcome)})}
    end)
  end

  defp operation_id!(id) when is_binary(id), do: id

  defp operation_id!(id) do
    raise ArgumentError, "the operation ID must be a string, got: #{inspect(id)}"
  end

  defp executors!(executors) when is_map(executors), do: executors

  defp executors!(nil),
    do: raise(ArgumentError, ":executors is required, a map of source to executor")

  defp executors!(_executors),
    do: raise(ArgumentError, ":executors must be a map of source to executor")

  defp outcome_kind({:ok, _result}), do: :ok
  defp outcome_kind({:error, %Tama.Dex.Error{kind: kind}}), do: kind
  defp outcome_kind({:error, %{operation_error: _error}}), do: :operation_error

  @doc false
  @spec cassette!(term()) :: cassette()
  def cassette!(name) when is_binary(name) do
    if Regex.match?(@cassette_name, name) do
      name
    else
      raise ArgumentError,
            "invalid cassette name #{inspect(name)}, must match #{inspect(@cassette_name.source)}"
    end
  end

  def cassette!(nil), do: raise(ArgumentError, "a :cassette name is required")
  def cassette!(name), do: raise(ArgumentError, "invalid cassette name #{inspect(name)}")
end
