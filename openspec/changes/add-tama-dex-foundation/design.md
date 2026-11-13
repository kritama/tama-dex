# Design

## Context

- **First producer:** `opsmaru_incus` 0.1.0 (Hex, 2026-11-12).
  - It exports 32 operations. Each descriptor gives the operation's name,
    title, description, scope, destructive flag, confirmation
    (`%{"field" => "confirm", "value" => "the full fingerprint"}` or `nil`),
    bounds, input and output schemas, and the client evidence it requires.
  - Scopes are `incus.read` (22), `incus.write` (5), `incus.exec` (1) and
    `incus.delete` (4). Output schemas are `oneOf` a success object and an
    `error` object.
  - Its run function re-checks scopes and confirmation, validates the input,
    asks the host to authorize and only then contacts Incus.
  - It doesn't publish profile documents yet; that is planned for 0.2.0, in
    opsmaru-incus's own change. tama-dex names no producer modules.
- **First host:** Macus (upmaru/macus#9, `feature/elixir-server`).
  - `/mcp` advertises exactly `search` and `execute`.
  - Its catalogue combines `opsmaru_incus` operations with Macus runtime
    operations, and operations the producer marks unavailable are excluded.
    With cassette namespaces (Decision 3), names need only be unique within
    one cassette.
  - `execute` passes the caller's verified scopes into the producer's run
    function, so the MCP tool scope is only an outer gate. `search` filters by
    the caller's scopes.
  - It has recorded open questions on index ownership (see below).
- **Kritama conventions (`tama_mcp` 0.2.0):** Elixir 1.19.5 on OTP 27.3.4.16,
  Apache-2.0, `mix precommit` (format check, warnings as errors, Credo strict,
  tests with coverage), Dialyzer, Git Flow with `develop` as the default
  branch, and Conventional Commits. `tama_mcp` validates JSON Schema 2020-12
  with `jsonschex`. Its tools are compile-time modules with fixed scopes, and
  raw schemas are allowed.
- **Dependencies:** exqlite 0.43.0 compiles SQLite with
  `SQLITE_ENABLE_FTS5=1`. tama-dex uses the latest jsonschex, 0.11.2
  (`~> 0.11.2`). tama_mcp 0.2.0 still requires `~> 0.10.0`, so a host such
  as Macus can combine the two only after a tama_mcp release moves to
  `~> 0.11.2`. That bump is a separate change in tama-mcp.

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

- **Index process:** `Tama.Dex.Index.start_link(opts)` starts one GenServer
  that holds the index's state and links two worker processes, each owning
  one exqlite connection. The reader runs `search`, `describe` and lookups.
  The writer runs loads and imports, one at a time. The index process does
  no SQLite work itself, so its state (such as readiness) answers without
  waiting on SQLite. It forwards each query to the reader, which replies to
  the caller directly. A write's result goes back through the index process,
  which updates its state before replying.
  - In WAL mode, readers keep seeing the last committed state while a write is
    in progress, so a background import never blocks searches in a
    file-backed index.
  - For `:memory`, both connections open one in-memory database through the
    `memdb` VFS, under a name unique to the index process
    (`file:/tama-dex-<unique>?vfs=memdb`), so the writer's commits are
    visible to reads. `memdb` has no WAL, so the connections use
    rollback-journal locks. A read during a write may keep seeing the
    previous state until the writer takes its exclusive lock to commit, and
    then waits for the commit under the read connection's busy timeout. The
    writer may likewise wait for in-flight reads under its own busy timeout.
    A read never sees a mixture. `:memory` is meant for tests and
    short-lived hosts.
  - Rejected for `:memory`: a shared-cache database. Its table locks fail
    reads with `SQLITE_LOCKED` during a write, and a busy timeout does not
    apply to them.
  - Options: `path:` (required; a file path or `:memory`), `name:` (optional),
    `limits:` (optional, never above the profile limits).
  - The host decides where the database lives (Macus:
    `<state-dir>/server/tama-dex.sqlite3`). The file is created mode 0600.
  - One index holds every cassette. Each cassette is a namespace inside it
    (Decision 3), not a separate database file.
  - Opening runs `PRAGMA journal_mode=WAL` and `foreign_keys=ON`.
- **Compiled schema cache:** input and response schemas are compiled with
  jsonschex lazily, on an operation's first execute, and cached in a public
  ETS table owned by the index process, keyed by the SHA-256 of the stored
  schema text.
  - Opening an index compiles nothing, so a large index never delays the
    host's supervisor.
  - Reads (`search`, lookup for `execute`) are short queries on the read
    connection, and never wait behind a load or import. The lookup returns
    the committed row, and its schema text gives the cache key, so a reload
    needs no cache swap and a caller never pairs a new row with an old
    schema. Validation and dispatch run in the caller's process.
  - After each commit or unload, the index process drops cache entries that
    no row references any more.
  - So neither a slow executor nor a running import blocks the index.
- **Public API:**

```elixir
Tama.Dex.Profile.validate(document) :: {:ok, Tama.Dex.Document.t()} | {:error, [Tama.Dex.Profile.Issue.t()]}
Tama.Dex.load(index, document, cassette: name, timeout: ms)
  :: {:ok, %{cassette, source, operations, changed}} | {:error, term}
Tama.Dex.import(index, path, sha256: pin, as: name, timeout: ms, async: boolean)
  :: {:ok, %{cassette, version, mode, changed, sources: [...]}} | {:ok, reference} | {:error, term}
Tama.Dex.Index.status(index)        :: :ready | :empty | {:importing, progress} | {:failed, reason}
Tama.Dex.unload(index, cassette)    :: :ok
Tama.Dex.cassettes(index)           :: [%{cassette, kind, version, status, mode, digest, loaded_at, sources: [...]}]
Tama.Dex.search(index, query, opts) :: {:ok, %{results: [...], truncated: boolean}} | {:error, :not_ready}
Tama.Dex.describe(index, cassette, operation_id, scopes: scopes) :: {:ok, map} | {:error, :not_found | :not_ready}
Tama.Dex.execute(index, cassette, operation_id, input,
                 scopes: scopes, executors: %{source => module | {module, opts}}, context: term)
  :: {:ok, %{cassette, operation_id, source, result}}
   | {:error, %{cassette, operation_id, source, operation_error}}
   | {:error, Tama.Dex.Error.t()}
Tama.Dex.MCP.search_tool() / execute_tool()          # definitions as data
Tama.Dex.MCP.handle_search(index, args, caller)      # JSON-safe map
Tama.Dex.MCP.handle_execute(index, args, caller, executors)

@callback Tama.Dex.Executor.execute(Tama.Dex.Call.t(), input :: map) :: {:ok, map} | {:error, map}
%Tama.Dex.Call{cassette, source, operation_id, scopes, context, opts}
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
- **Validation:** `Tama.Dex.Profile.validate/1` is pure. It validates the
  document shape against `priv/profile/tama-operations-1.schema.json`, then
  applies the semantic rules JSON Schema can't express:
  - the path suffix equals `operationId`;
  - IDs are unique within the document;
  - the confirmation field is a required top-level string property, and
    identity names are top-level properties, read through a top-level `$ref`
    but never inside `allOf`/`anyOf`/`oneOf` (as the profile defines);
  - `$ref`s are internal and resolvable;
  - every operation schema compiles under jsonschex;
  - size and count limits hold.

  It returns every issue, each with a JSON pointer, a stable code and a
  bounded message. Internal `$ref`s are resolved by bundling
  `components.schemas` into each compiled schema as `$defs`.

### 3. Cassette namespaces, loading and replacement

On 2026-11-12 the user chose one host-owned index in which every cassette is a
namespace.

- **Cassette name:** matches `^[a-z][a-z0-9_]{0,63}$`, for example
  `opsmaru_incus` or `macus`. It is stable across versions, so references
  held by agents survive upgrades. The version is reported, never used to
  address an operation.
- **Kinds:**
  - **Imported:** installed from a cassette file. Its name comes from the
    cassette manifest, or from the host's `as:` option, which resolves name
    collisions between producers.
  - **Local:** built by `load/3` from documents the host holds, under the
    host-given `cassette:` name. Macus loads its runtime document into a
    local `macus` cassette.

  A name belongs to one kind. Loading into an imported cassette's name, or
  importing over a local cassette's name, fails with `cassette_conflict` and
  changes nothing.
- **Uniqueness:** source IDs and `operationId`s are unique within a cassette,
  across its sources. The same `operationId`, or even the same source, may
  appear in two cassettes. Operations are addressed by
  `(cassette, operation_id)`.
- **Executors** stay keyed by source, because the host's executor is the code
  that runs a source's operations. Two cassettes carrying the same source use
  the same executor.
- **Import replaces a whole cassette** in one transaction: its previous
  sources and operations are deleted and the new ones inserted, so an
  operation dropped in a new version disappears. Other cassettes are never
  touched.
- **`load/3`** replaces one source inside a local cassette:
  1. Validates the whole document.
  2. Computes the SHA-256 digest of its canonical JSON (sorted keys, no
     insignificant whitespace).
  3. If that source is already loaded in that cassette with the same digest
     and profile, returns `changed: false` without writing.
  4. Otherwise, in one transaction: rejects any `operationId` already owned by
     another source of the same cassette (`duplicate_operation`, listing the
     IDs and owning source, with no change), deletes the source's rows,
     inserts the new ones, rebuilds their FTS rows and commits.
  5. Leaves the compiled-schema cache alone. Entries are keyed by schema
     digest, so the next execute compiles any new schema on first use.

  A failed load or import leaves the cassette's previous entries intact.
- **`unload/2`** removes a whole cassette.
- **Rejected alternative, one SQLite file per cassette:** it avoids copying at
  startup, but FTS5 `bm25` scores are per database, so results could only be
  interleaved by position, not ranked together. It also needs a connection or
  `ATTACH` slot per cassette (10 by default), swapping and detach handling,
  and a separate rebuilt file for every unpinned cassette. The public API
  above would barely change, so this can be revisited if a host needs
  zero-copy startup or many large cassettes.

### 4. Storage schema (version 1)

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);            -- schema_version = 1
CREATE TABLE cassettes (cassette TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('imported', 'local')),
  version TEXT, content_digest TEXT, file_sha256 TEXT, mode TEXT, loaded_at TEXT NOT NULL);
CREATE TABLE sources (cassette TEXT NOT NULL REFERENCES cassettes(cassette) ON DELETE CASCADE,
  source TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL, profile TEXT NOT NULL,
  digest TEXT NOT NULL, loaded_at TEXT NOT NULL, PRIMARY KEY (cassette, source));
CREATE TABLE operations (id INTEGER PRIMARY KEY, cassette TEXT NOT NULL, source TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  summary TEXT NOT NULL, description TEXT NOT NULL, tags TEXT NOT NULL, scopes TEXT NOT NULL,
  destructive INTEGER NOT NULL, deprecated INTEGER NOT NULL, confirmation TEXT, bounds TEXT,
  identity TEXT,
  input_schema TEXT NOT NULL, input_schema_digest TEXT NOT NULL,
  success_schema TEXT NOT NULL, success_schema_digest TEXT NOT NULL,
  error_schema TEXT, error_schema_digest TEXT, extensions TEXT,
  UNIQUE (cassette, operation_id),
  FOREIGN KEY (cassette, source) REFERENCES sources(cassette, source) ON DELETE CASCADE);
CREATE INDEX operations_source ON operations (cassette, source);
CREATE VIRTUAL TABLE operations_fts USING fts5(operation_id, summary, tags, description, fields,
  tokenize='unicode61');                                                  -- rowid = operations.id
```

- JSON columns hold canonical JSON. Schema columns hold the bundled schemas,
  and each `*_schema_digest` is the SHA-256 of that text: the compiled-schema
  cache key, and what the index checks to drop cache entries no row
  references. `identity` holds the `x-tama-identity` names.
- `fields` is the space-joined top-level input property names and their
  descriptions, read as the profile defines top-level properties, so
  `fingerprint` finds `incus_image_delete`.
- `unicode61` splits on `_`, so `incus_instance_list` matches `instance`.
- The FTS table stores its own copy of the text, since catalogues are small.
  Its rows are written and deleted alongside `operations`, sharing
  `operations.id` as the rowid. That avoids contentless FTS5 delete
  limitations.
- Every cassette shares the one FTS table, so `bm25` ranks all cassettes'
  operations together.
- On open, a missing `meta` table means the database is created. A
  `schema_version` other than 1 means every table is dropped and recreated
  empty, a `{:recreated, old}` telemetry event fires, and the host reloads its
  documents. A newer version is never written by older code.
- The schema version covers both the table definitions and how rows are
  derived from documents: canonical JSON, bundled schemas, the FTS text and
  any truncation. A change to either needs a new version, so rows built by
  two tama-dex releases with the same schema version are interchangeable.

### 5. Search

- **Query:** the caller's text (at most 512 bytes) is split into terms of
  letters and digits. Each term is quoted and given a prefix wildcard
  (`"inst"*`), and terms are joined with AND. Raw FTS5 syntax never reaches
  SQLite, so `"`, `NEAR`, `*`, `:`, `-` and `OR` from callers are inert.
  Longer text raises `ArgumentError` (`invalid_arguments` from the MCP
  handler), and text with no terms is an empty query.
- **Empty query:** lists the visible operations in `(cassette, operation_id)`
  order.
- **Exact match:** an `operation_id` that matches exactly ranks first. If
  several cassettes have it, they are ordered by cassette name.
- **Ranking:** `bm25(operations_fts, 10.0, 5.0, 3.0, 1.0, 1.0)`.
- **Filters:**
  - `scopes:` is required. An operation is visible only if all its scopes
    are in the caller's verified scopes.
  - Optional: `cassette:`, `source:`, `tags:` (operations carrying every
    listed tag), `include_deprecated:` (default false) and
    `include_destructive:` (default true).
- **Limits:** `limit` defaults to 5. A limit outside 1–20 raises
  `ArgumentError` (`invalid_arguments` from the MCP handler). Results are
  ordered by rank, then cassette, then `operation_id`.
- **Result fields:** `cassette`, `cassette_version`, `operation_id`, `source`,
  `summary`, `description` (truncated to 1024 characters with a flag),
  `tags`, `scopes`, `destructive`, `deprecated`, `confirmation`, `bounds`, and
  `input_schema` when `include_schemas` (default true).
- **Byte budget:** the whole result stays within 64 KiB of JSON. Schemas are
  dropped from the lowest-ranked results first, each marked
  `schema_omitted: true`. `truncated: true` is set if results themselves had
  to be cut.
- **`describe/4`:** returns one visible operation, addressed by cassette and
  `operation_id`, in full, including the response schemas and opaque
  extensions.

### 6. Execute

`execute/5` runs in the caller's process. It takes the cassette and the
`operation_id`; the cassette is required, so mounting a new cassette that
reuses a name can never make a working call ambiguous. Each step stops at its
first error:

1. **Lookup:** the operation is looked up in that cassette only. An unknown
   cassette, an unknown operation, or one not visible to `scopes` returns
   `not_found`, so execute can't be used to discover hidden operations or
   cassettes. A cassette whose first import is still running returns
   `not_ready`.
2. **Executor:** `executors[source]` must be a module implementing
   `Tama.Dex.Executor`, or `{module, opts}`, otherwise `no_executor` (Decision
   11). It is called as `module.execute(call, input)` with a
   `%Tama.Dex.Call{}` and returns `{:ok, map} | {:error, map}`.
3. **Input shape:** must be a JSON object (a map with string keys and JSON
   values) at most 1 MiB once encoded, otherwise `invalid_input`. Atom keys
   are rejected here rather than silently failing the schema.
4. **Confirmation:** when `x-tama-confirmation` is set, a missing or empty
   field returns `confirmation_required`, with the field and description.
   This runs before schema validation: the profile requires the confirmation
   field to be a required property, so validating the schema first would
   report a missing confirmation as `invalid_input`.
5. **Input schema:** the input is validated against the compiled input
   schema, and failures return `invalid_input` with at most 16 JSON-pointer
   issues. Each names the failed keyword and the schema's constraint, never
   the input value, and a missing property is reported at its own pointer.
6. **Dispatch:** called exactly once, with no deadline added by tama-dex.
   Macus runtime start can legitimately run up to 600 s by default, with a
   caller budget of 1–3600 s. Timeouts belong to the executor and host, which
   return progress or a `running` status rather than being cut off locally.
   Raises, exits and throws are caught and returned as `dispatch_failed`, with
   the kind and nothing else. tama-dex never retries.
7. **Result check:** the executor must return `{:ok, map}` or
   `{:error, map}`, with a map that is JSON data (string keys, JSON values)
   even when no `default` is declared. `{:ok, result}` must match the `200` schema, and
   `{:error, error}` must match `default` when declared. Anything else returns
   `invalid_output`, without the result's content. It does carry the values of
   the operation's `x-tama-identity` properties (top-level strings, integers
   or booleans, each at most 256 bytes) when the raw result has them, so a
   caller can reconcile an operation that may already have taken effect.
8. **Return:** `{:ok, %{cassette, operation_id, source, result}}`, or, for
   the executor's own valid error,
   `{:error, %{cassette, operation_id, source, operation_error: error}}` with
   `error` unchanged. Callers match `%Tama.Dex.Error{}` first. An operation
   error always means the operation ran.

`Tama.Dex.Error` has `kind`, `dispatched` (boolean), a bounded `message` and
optional bounded `details`. Only `execute/5` returns it. `search/3` and
`describe/4` dispatch nothing, so they return bare `{:error, :not_found}` or
`{:error, :not_ready}`. The MCP handlers encode both forms as `error` objects
with a `kind` and `dispatched`.

- **`dispatched: false`:** steps 1–5 (`not_found`, `not_ready`,
  `no_executor`, `invalid_input`, `confirmation_required`). The operation did
  not run.
- **`dispatched: true`:** `dispatch_failed` and `invalid_output`. The
  operation may have taken effect. The message says so, and callers must
  reconcile, never retry blindly. Inputs and results are never logged,
  stored or sent in telemetry.

### 7. MCP tool definitions

`Tama.Dex.MCP.search_tool/0` and `execute_tool/0` return
`%{name, title, description, input_schema, output_schema, annotations}`.

- **`search` input:** `{query?, cassette?, source?, tags?, limit?,
  include_schemas?}`. Each result carries its `cassette`.
- **`execute` input:** `{cassette, operation_id, input}`, all required. The
  agent copies `cassette` and `operation_id` from a search result.
- **Not ready:** both handlers return a `not_ready` error object while the
  index has nothing committed.
- **`search` output** is `{results, truncated}` or a tama-dex error object.
- **`execute` output** is one of:
  - a result: `{cassette, operation_id, source, result}`;
  - an operation error, the executor's own valid error:
    `{cassette, operation_id, source, operation_error, dispatched: true}`;
  - a tama-dex error: `{error: {kind, dispatched, message, details?}}`.
- **Handlers:** `handle_search/3` and `handle_execute/4` take a `caller`:
  any map or struct with a `scopes` field holding the verified scope list,
  such as `TamaMCP.Context`, so tama-dex needs no tama_mcp dependency. The
  whole caller becomes `call.context`. A caller without a scope list raises
  `ArgumentError`. Handlers return JSON-safe maps.
- **Invalid arguments:** arguments that aren't a JSON object, or fail the
  tool's input schema, or carry a query over 512 bytes, return
  `invalid_arguments` (`dispatched: false`) with at most 16 JSON-pointer
  issues, before any lookup.
- **Hosts:** with TamaMCP, a host declares two tool modules using
  `raw_input_schema` and `raw_output_schema` from these definitions, and calls
  the handlers from `call/2`. TamaMCP takes only literal schemas, so the host
  injects the definitions with a macro at compile time (shown in the README).
  Each tool's own scope is only an outer gate.
- No `tama_mcp` dependency in v1, not even for tests. A test checks schema
  identity with a host-style module instead. An optional adapter can come
  later.

### 8. Telemetry

- **Events:**
  - `[:tama_dex, :load | :import | :search | :execute, :start | :stop |
    :exception]`;
  - `[:tama_dex, :index, :recreated]`, when a database with an unknown schema
    version is recreated;
  - `[:tama_dex, :index, :status]`, on each change of
    `Tama.Dex.Index.status/1` (Decision 10).
- **Metadata:** limited to the cassette, source, operation ID, import mode,
  `changed`, status, counts, result kind and durations. Never query text
  beyond its length, inputs, results, schemas or file paths.

### 9. Cassettes

A cassette is a prebuilt index that a producer's CI publishes and a host
imports. The user's target flow:
1. An opsmaru_incus release runs indexing in CI and attaches the cassette, its
   SHA-256 and a provenance attestation to the GitHub Release.
2. Macus's own release build downloads the cassette for its locked
   opsmaru_incus version, verifies it, and bundles the file with its SHA-256
   as the pin.
3. At `macus start`, Macus imports the bundled local file. Nothing is
   downloaded at startup, by Macus or by tama-dex.

- **Format `tama-cassette/1`:** one SQLite file holding one cassette: the
  version 1 index tables, whose `cassette` column holds only its name, plus:
  - `cassette_manifest`, with the format, cassette name and version, tama-dex
    version, index schema version, SQLite version, profile and content
    digest;
  - `cassette_documents(source, digest, document)`, with each source's
    canonical JSON.

  The content digest is the SHA-256 of the format, the cassette name and
  version, the index schema version and the sorted `(source, document digest)`
  pairs. A cassette stores no
  wall-clock time, so `loaded_at` is set at import. The build ends with
  `VACUUM`, so the file is compact. Identical bytes are not guaranteed across
  SQLite versions, so identity is the content digest.
- **Build:** `Tama.Dex.Cassette.build(documents, path, name: name, version:
  version)` validates every document, rejects duplicate sources and IDs
  within the cassette, writes to a temporary file and renames it into place.
  `mix tama.dex.cassette --name opsmaru_incus --version 0.2.0 --document
  Mod.fun ... --file doc.json ... --output path` runs in a producer's CI, calling
  zero-arity functions from the project's code or reading JSON files, and
  prints the content digest and file SHA-256. tama_dex is then only a
  dev/test dependency of the producer.
- **Verify:** `Tama.Dex.Cassette.verify(path, sha256: pin)` treats the file as
  untrusted. It:
  - checks the size limit (64 MiB) and, when given, the file SHA-256;
  - opens the file read-only, with extension loading off;
  - requires `sqlite_master` to hold exactly the expected tables, indexes and
    FTS shadow tables, with no triggers or views;
  - checks the manifest format and cassette name;
  - recomputes every embedded document's digest and the content digest;
  - validates every document against the profile.

  It returns the manifest or bounded issues.
- **Import:** `Tama.Dex.import(index, path, sha256: pin, as: name)` verifies
  first, then replaces the whole cassette (Decision 3) in one transaction,
  under the manifest name or `as:`.
  - **Copy mode** is used only when the host passed a matching `sha256` pin
    and the index schema version matches. Rows are copied from the attached
    read-only cassette, with the `cassette` column set to the installed name.
    `operations.id` is shared across the whole index, so copied rows get new
    IDs, and their FTS rows are inserted under those IDs.
  - **Rebuild mode** is used otherwise: without a pin, or with a different
    index schema version. Each embedded document is loaded as `load/3` would.
    A different tama-dex version alone never forces a rebuild, because the
    index schema version covers how rows are derived (Decision 4).
  - Importing the same content digest again reports `changed: false` and
    writes nothing.
  - The result reports the cassette, version, mode, `changed` and its
    sources. An unpinned cassette therefore can't inject index rows that
    differ from its verified documents.
- **Fixtures:** a cassette is a SQLite file, so none is committed. Tests
  build cassettes in temporary directories. Producer evidence uses checked-in
  JSON documents, and a release cassette is read from `.integration/` by an
  opt-in integration test (task 9.1).
- **Several cassettes:** a host imports each cassette separately. They
  coexist in the one index, and searches rank across all of them.
- **Hosts** choose where cassettes come from, such as an asset bundled at
  build time or downloaded and pinned by digest. tama-dex never downloads
  anything.

### 10. Startup budget and readiness

Hosts index during startup: Macus runs one serialized bootstrap with a single
deadline. Search must never block or fail VM startup; the index is gateway
readiness that may lag runtime readiness.

- **Deadlines:** `load/3` and `import/3` accept `timeout:` (milliseconds).
  Work runs in the index's writer process, inside one transaction. When the
  deadline passes, the transaction is rolled back, the previous entries stay
  in place, and the call returns `{:error, :deadline}`. Without `timeout:`,
  the call waits until the work finishes: tama-dex never applies a default
  call timeout such as `GenServer.call/2`'s 5 seconds.
- **Background import:** `import(index, path, async: true, ...)` returns
  `{:ok, ref}` once the cassette has been checked for size and file SHA-256,
  and imports in the index's writer. When it finishes, the calling process
  receives `{:tama_dex_import, ref, result}`, where `result` is what a
  synchronous import would have returned.
  - `Tama.Dex.Index.status/1` reports the index's readiness as a whole, and
    emits `[:tama_dex, :index, :status]` on each change:
    - `:ready` whenever at least one cassette is committed, even while other
      imports run or after one has failed;
    - otherwise `{:importing, %{cassette, done: n, total: m}}` while a load
      or import runs;
    - otherwise `{:failed, reason}` if the last attempt failed;
    - otherwise `:empty`.
  - `Tama.Dex.cassettes/1` reports each cassette's own status, so a host that
    imports several cassettes can tell when all of them are installed. `:ready`
    from `status/1` means at least one cassette is committed, not all of them.
  - A host can wait for the `{:tama_dex_import, ref, result}` message, or
    poll `cassettes/1`.
- **Not-ready behaviour:** `search/3` and `describe/4` return
  `{:error, :not_ready}`, and `execute/5` returns a `not_ready` error with
  `dispatched: false`, only while the index has no committed cassette and an
  import or load is running. `describe/4` and `execute/5` also do so for a
  cassette whose first import is still running. The check reads the index's
  in-memory status, so it never waits on SQLite. In a file-backed index, a
  cassette being re-imported keeps serving its previous entries until the
  commit. An in-memory index may make those reads wait (Decision 1).
- **Performance target:** rebuilding a 1024-operation document set completes
  within 2 s on a GitHub-hosted runner, and copy mode faster. This is measured
  as release evidence (task 8.4), not asserted in unit tests.

### 11. Executor contract

On 2026-11-12 the user chose an Elixir behaviour for the calling side.

- **`Tama.Dex.Executor`** has one callback, `execute(call, input)`. The
  `%Tama.Dex.Call{}` carries the cassette, source, operation ID, the verified
  scopes tama-dex checked, the host `context` (the caller, for the MCP
  handler) and the registration `opts`. Passing the checked scopes in the
  call means the executor re-checks exactly what tama-dex saw, and the host
  never supplies scopes twice.
- **Registration:** `%{source => module | {module, opts}}`. Anything else, or
  a module without `execute/2`, is `no_executor` before dispatch.
- **Who implements it:** host adapter modules. A producer's run function
  needs host-only arguments (for example the host's authorization module and
  the verified caller), so the adapter is host glue. Producers keep no
  compile-time or runtime dependency on tama_dex: they publish documents as
  data and their own run functions.
- **Indexing stays a data contract.** The `tama-operations/1` document is the
  ingestion standard. A behaviour for producing documents would add nothing
  the validator doesn't check, and would make producers compile against
  tama_dex.
- **Not a protocol:** protocols dispatch on a value's type. Executors are
  chosen by source ID, so a behaviour plus a registry map fits.
- **Rejected:** keeping bare 3-arity functions and MFAs. They give no
  compile-time `@impl` check, no Dialyzer contract and no single documented
  call shape.

## Risks

- **FTS ranking quality** is lexical. Mitigations: weighted columns, exact-ID
  boost, prefix terms, and indexed input field names. Semantic search is a
  later change.
- **A producer emitting a slightly wrong document** makes the load fail
  loudly, with pointers, and leaves the previous version in place. Producers
  get `Tama.Dex.Profile.validate/1` and fixtures for their tests.
- **A tampered or malformed cassette:** a SHA-256 pin is required for copy
  mode. Otherwise the index is rebuilt from documents whose digests were
  verified. A strict check of `sqlite_master` rejects triggers and views, and
  the cassette is opened read-only.
- **Agents addressing the wrong cassette:** `execute` requires the cassette
  and looks only there, so a call never silently runs another cassette's
  operation of the same name.
- **Concurrent hosts on one database file:** only one host process should own
  a database path. WAL keeps reads consistent, but the design assumes a single
  writer.

## Confirmed host defaults

The user confirmed these Macus defaults on 2026-11-12:

1. **Who builds the index?** The host, at startup: Macus imports the bundled,
   SHA-pinned `opsmaru_incus` cassette and loads its runtime document into a
   local `macus` cassette. tama-dex never fetches documents or cassettes.
2. **Where does the index live?** A host-chosen path (Macus:
   `<state-dir>/server/tama-dex.sqlite3`), or `:memory`.
3. **Who owns `search`?** The host owns the MCP tool modules, and tama-dex
   provides the tool definitions and handlers. An optional TamaMCP adapter
   inside tama-dex is deferred.
