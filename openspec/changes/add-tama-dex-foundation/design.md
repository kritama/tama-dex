# Design

## Context

- **First producer:** `opsmaru_incus` 0.1.0 (Hex, 2026-11-12).
  - `Opsmaru.Incus.Operations.all/0` lists 32 operations, and `describe/1`
    returns each one's name, title, description, scope, destructive flag,
    confirmation (`%{"field" => "confirm", "value" => "the full fingerprint"}`
    or `nil`), bounds, input and output schemas, and the client evidence it
    requires.
  - Scopes are `incus.read` (22), `incus.write` (5), `incus.exec` (1) and
    `incus.delete` (4). Output schemas are `oneOf` a success object and an
    `error` object.
  - `Operations.run(name, input, host:, caller:, scopes:)` re-checks scopes and
    confirmation, validates the input, asks the host to authorize and only then
    contacts Incus.
  - The library has no `openapi/0` yet.
- **First host:** Macus (upmaru/macus#9, `feature/elixir-server`).
  - `/mcp` advertises exactly `search` and `execute`.
  - Its catalogue combines `opsmaru_incus` operations with Macus runtime
    operations. Duplicate names fail, and `Operations.unavailable/0` entries
    are excluded.
  - `execute` passes the caller's verified scopes into `run/3`, so the MCP tool
    scope is only an outer gate. `search` filters by the caller's scopes.
  - It has recorded open questions on index ownership (see below).
- **Kritama conventions (`tama_mcp` 0.2.0):** Elixir 1.19.5 on OTP 27.3.4.16,
  Apache-2.0, `mix precommit` (format check, warnings as errors, Credo strict,
  tests with coverage), Dialyzer, Git Flow with `develop` as the default
  branch, and Conventional Commits. `tama_mcp` validates JSON Schema 2020-12
  with `jsonschex`. Its tools are compile-time modules with fixed scopes, and
  raw schemas are allowed.
- **Dependencies:** exqlite 0.43.0 compiles SQLite with
  `SQLITE_ENABLE_FTS5=1`. jsonschex is at 0.11.2.

## Goals

- One producer-neutral ingestion standard, with a pure validator producers can
  run in their tests.
- A durable, host-owned index that loads in milliseconds, so hosts can rebuild
  it at startup.
- Search that returns enough for an agent to call `execute` correctly, without
  revealing operations the caller cannot run.
- `execute` that fails before dispatch on everything it can check, and never
  replays.

## Non-goals

- Running operations, authorization policy beyond scope checks, confirmation
  value checks, or timeouts. These stay with producers and hosts.
- An MCP server, HTTP transport, fetching documents over the network, or
  embeddings or semantic search. Search is lexical (FTS5) in v1.
- Storing execution history, inputs or results.

## Decisions

### 1. Library shape and processes

The library has no `Application` module.

- **Index process:** `TamaDex.Index.start_link(opts)` starts one GenServer.
  It owns a single exqlite connection and serializes loads.
  - Options: `path:` (required; a file path or `:memory`), `name:` (optional),
    `limits:` (optional, never above the profile limits).
  - The host decides where the database lives (Macus default:
    `<state-dir>/server/tama-dex.sqlite3`). The file is created mode 0600.
  - Opening runs `PRAGMA journal_mode=WAL` and `foreign_keys=ON`.
- **Compiled schema cache:** input and response schemas are compiled with
  jsonschex. The index process holds them in a protected ETS table keyed by
  operation and document digest.
  - Reads (`search`, lookup for `execute`) run in the caller's process. They
    use a short read through the index process, and validation runs against
    the ETS cache.
  - So a slow executor never blocks the index.
- **Public API:**

```elixir
TamaDex.Profile.validate(document) :: {:ok, TamaDex.Document.t()} | {:error, [TamaDex.Profile.Issue.t()]}
TamaDex.load(index, document)      :: {:ok, %{source: s, operations: n, changed: boolean}} | {:error, term}
TamaDex.unload(index, source)      :: :ok
TamaDex.sources(index)             :: [%{source, title, version, profile, digest, operations, loaded_at}]
TamaDex.search(index, query, opts) :: {:ok, %{results: [...], truncated: boolean}}
TamaDex.describe(index, operation_id, scopes: scopes) :: {:ok, map} | {:error, :not_found}
TamaDex.execute(index, operation_id, input, scopes: scopes, executors: %{source => executor}, context: term)
  :: {:ok, %{operation_id, source, result}} | {:error, TamaDex.Error.t()}
TamaDex.MCP.search_tool() / execute_tool()          # definitions as data
TamaDex.MCP.handle_search(index, args, caller)      # JSON-safe map
TamaDex.MCP.handle_execute(index, args, caller, executors)
```

### 2. Ingestion standard: OpenAPI 3.1 with `x-tama-*` extensions

The profile itself is defined in `docs/tama-operations-profile.md`.

- **Why OpenAPI 3.1:** its schemas are JSON Schema 2020-12, so producers' JSON
  schemas (opsmaru's included) drop in unchanged. It is a standard that
  existing tools can read, and it can describe non-HTTP operations by
  convention (`POST /operations/{id}`).
- **Rejected alternatives:**
  - A bespoke descriptor format: every producer would need a tama-dex-specific
    shape, and no tooling could read it.
  - Indexing opsmaru's `describe/1` maps directly: that couples tama-dex to
    one library's internals, and Macus's runtime operations would need a
    second format.
- **What the extensions carry:** what OpenAPI lacks. Scopes are
  `x-tama-scopes`, not `security`, because a standard OAuth2 security scheme
  requires flow URLs that local libraries don't have.
- **How opsmaru maps onto it:**
  - `name` → `operationId`, `title` → `summary`, `description` →
    `description`.
  - `scope` → `x-tama-scopes: [scope]`, `destructive` → `x-tama-destructive`.
  - `confirmation.field` / `value` → `x-tama-confirmation.field` /
    `description`.
  - `bounds` → `x-tama-bounds`, `requires` → `x-opsmaru-requires`.
  - `x-tama-identity: ["operation_id", "status"]` for operations whose results
    carry them.
  - The success branch of `output_schema` → `200`, and the error branch →
    `default`.
- **Validation:** `TamaDex.Profile.validate/1` is pure. It validates the
  document shape against `priv/profile/tama-operations-1.schema.json`, then
  applies the semantic rules JSON Schema can't express:
  - the path suffix equals `operationId`;
  - IDs are unique;
  - the confirmation field is a required string property;
  - `$ref`s are internal and resolvable;
  - every operation schema compiles under jsonschex;
  - size and count limits hold.

  It returns every issue, each with a JSON pointer, a stable code and a
  bounded message. Internal `$ref`s are resolved by bundling
  `components.schemas` into each compiled schema as `$defs`.

### 3. Loading and replacement

`TamaDex.load/2`:

1. Validates the whole document.
2. Computes the SHA-256 digest of its canonical JSON (sorted keys, no
   insignificant whitespace).
3. If the source is already loaded with the same digest and profile, returns
   `changed: false` without writing.
4. Otherwise, in one transaction: rejects any `operationId` already owned by
   another source (error lists the IDs and the owning source, and nothing
   changes), deletes the source's rows, inserts the new ones, rebuilds that
   source's FTS rows and commits.
5. Swaps the compiled-schema cache entries only after the commit.

A failed load leaves the previous entries of that source intact.

### 4. Storage schema (version 1)

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);            -- schema_version = 1
CREATE TABLE sources (source TEXT PRIMARY KEY, title TEXT NOT NULL, version TEXT NOT NULL,
  profile TEXT NOT NULL, digest TEXT NOT NULL, loaded_at TEXT NOT NULL);
CREATE TABLE operations (operation_id TEXT PRIMARY KEY,
  source TEXT NOT NULL REFERENCES sources(source) ON DELETE CASCADE,
  summary TEXT NOT NULL, description TEXT NOT NULL, tags TEXT NOT NULL, scopes TEXT NOT NULL,
  destructive INTEGER NOT NULL, deprecated INTEGER NOT NULL, confirmation TEXT, bounds TEXT,
  input_schema TEXT NOT NULL, success_schema TEXT NOT NULL, error_schema TEXT, extensions TEXT);
CREATE VIRTUAL TABLE operations_fts USING fts5(operation_id, summary, tags, description, fields,
  tokenize='unicode61');
```

- `fields` is the space-joined input property names and their descriptions,
  so `fingerprint` finds `incus_image_delete`.
- `unicode61` splits on `_`, so `incus_instance_list` matches `instance`.
- The FTS table stores its own copy of the text, since catalogues are small.
  Its rows are written and deleted alongside `operations`, joined on
  `operation_id`. That avoids contentless FTS5 delete limitations.
- On open, a missing `meta` table means the database is created. A
  `schema_version` other than 1 means every table is dropped and recreated
  empty, a `{:recreated, old}` telemetry event fires, and the host reloads its
  documents. A newer version is never written by older code.

### 5. Search

- **Query:** the caller's text (at most 512 bytes) is split into terms of
  letters and digits. Each term is quoted and given a prefix wildcard
  (`"inst"*`), and terms are joined with AND. Raw FTS5 syntax never reaches
  SQLite, so `"`, `NEAR`, `*`, `:`, `-` and `OR` from callers are inert.
- **Empty query:** lists the visible operations in `operation_id` order.
- **Exact match:** an `operation_id` that matches exactly ranks first.
- **Ranking:** `bm25(operations_fts, 10.0, 5.0, 3.0, 1.0, 1.0)`.
- **Filters:**
  - `scopes:` is required. An operation is visible only if all its scopes
    are in the caller's verified scopes.
  - Optional: `source:`, `tags:`, `include_deprecated:` (default false) and
    `include_destructive:` (default true).
- **Limits:** `limit` defaults to 5, maximum 20. Results are ordered by rank,
  then `operation_id`.
- **Result fields:** `operation_id`, `source`, `summary`, `description`
  (truncated to 1024 characters with a flag), `tags`, `scopes`, `destructive`,
  `deprecated`, `confirmation`, `bounds`, and `input_schema` when
  `include_schemas` (default true).
- **Byte budget:** the whole result stays within 64 KiB of JSON. Schemas are
  dropped from the lowest-ranked results first, each marked
  `schema_omitted: true`. `truncated: true` is set if results themselves had
  to be cut.
- **`describe/3`:** returns one visible operation in full, including the
  response schemas and opaque extensions.

### 6. Execute

`execute/4` runs in the caller's process. Each step stops at its first error:

1. **Lookup:** an unknown operation, or one not visible to `scopes`, returns
   `not_found`, so execute can't be used to discover hidden operations.
2. **Executor:** `executors[source]` must exist, otherwise `no_executor`. An
   executor is a 3-arity function or `{module, function, extra_args}`. It is
   called as `executor.(operation_id, input, context)` and returns
   `{:ok, map} | {:error, map}`.
3. **Input:** must be a map at most 1 MiB once encoded. It is validated
   against the compiled input schema, and failures return `invalid_input` with
   bounded JSON-pointer issues.
4. **Confirmation:** when `x-tama-confirmation` is set, a missing or empty
   field returns `confirmation_required`, with the field and description.
5. **Dispatch:** called exactly once, with no deadline added by tama-dex.
   Macus runtime start can legitimately run up to 600 s by default, with a
   caller budget of 1–3600 s. Timeouts belong to the executor and host, which
   return progress or a `running` status rather than being cut off locally.
   Raises, exits and throws are caught and returned as `dispatch_failed`, with
   the kind and nothing else. tama-dex never retries.
6. **Result check:** `{:ok, result}` must match the `200` schema, and
   `{:error, error}` must match `default` when declared. A mismatch returns
   `invalid_output`, without the result's content. It does carry the values of
   the operation's `x-tama-identity` properties (top-level strings, integers
   or booleans, each at most 256 bytes) when the raw result has them, so a
   caller can reconcile an operation that may already have taken effect.
7. **Return:** `{:ok, %{operation_id, source, result}}`, or the executor's
   `{:error, error}` passed through after it validates.

`TamaDex.Error` has `kind`, `dispatched` (boolean), a bounded `message` and
optional bounded `details`.

- **`dispatched: false`:** steps 1–4 (`not_found`, `no_executor`,
  `invalid_input`, `confirmation_required`). The operation did not run.
- **`dispatched: true`:** `dispatch_failed` and `invalid_output`. The
  operation may have taken effect. The message says so, and callers must
  reconcile, never retry blindly. Inputs and results are never logged, stored or sent in telemetry.

### 7. MCP tool definitions

`TamaDex.MCP.search_tool/0` and `execute_tool/0` return
`%{name, title, description, input_schema, output_schema, annotations}`.

- **`search` input:** `{query?, source?, tags?, limit?, include_schemas?}`.
- **`execute` input:** `{operation_id, input}`. The output is either a result
  object or an `error` object.
- **Handlers:** `handle_search/3` and `handle_execute/4` take the caller's
  verified scopes from `caller` and return JSON-safe maps.
- **Hosts:** with TamaMCP, a host declares two tool modules using
  `raw_input_schema` and `raw_output_schema` from these definitions, and calls
  the handlers from `call/2`. Each tool's own scope is only an outer gate.
- No `tama_mcp` dependency in v1. An optional adapter can come later.

### 8. Telemetry

- **Events:** `[:tama_dex, :load | :search | :execute, :start | :stop |
  :exception]` and `[:tama_dex, :index, :recreated]`.
- **Metadata:** limited to the source, operation ID, counts, result kind and
  durations. Never query text beyond its length, inputs, results or schemas.

## Risks

- **FTS ranking quality** is lexical. Mitigations: weighted columns, exact-ID
  boost, prefix terms, and indexed input field names. Semantic search is a
  later change.
- **A producer emitting a slightly wrong document** makes the load fail
  loudly, with pointers, and leaves the previous version in place. Producers
  get `TamaDex.Profile.validate/1` and fixtures for their tests.
- **Concurrent hosts on one database file:** only one host process should own
  a database path. WAL keeps reads consistent, but the design assumes a single
  writer.

## Open questions (user to confirm)

These are Macus's recorded questions, with the default this design assumes:

1. **Who builds the index?** The host, at startup, from the documents it holds:
   Macus loads `Opsmaru.Incus.Operations.openapi/0` plus its own runtime
   document. tama-dex never fetches documents.
2. **Where does the index live?** A host-chosen path (Macus:
   `<state-dir>/server`), or `:memory`.
3. **Who owns `search`?** The host owns the MCP tool modules, and tama-dex
   provides the tool definitions and handlers. An optional TamaMCP adapter
   inside tama-dex is deferred.
