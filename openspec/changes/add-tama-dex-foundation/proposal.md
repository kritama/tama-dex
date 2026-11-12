# Proposal

## Why

Hosts that expose operations to agents are collecting them from several
sources. Macus serves the 32 shared Incus operations from `opsmaru_incus`
(`Operations.all/0`) plus its own runtime operations. Central Opsmaru and Tama
will do the same. Exposing one MCP tool per operation floods `tools/list`. It
also forces each MCP tool scope to stand in for per-operation authorization.
And each source invents its own description format.

On 2026-11-04 the user chose an index-and-search design. tama-dex indexes the
operation specs of every source into SQLite, and the MCP server exposes only
two tools: `search` and `execute`, which validates calls against the indexed
operations. On 2026-11-12 the user asked for a standard that any producer can
publish against, so ingestion doesn't depend on any one library's internal
format. Macus has already rewritten its MCP spec around `search`/`execute`
(upmaru/macus#9). Its search task is blocked on this library.

## What Changes

- **Ingestion standard:** define the Tama operations profile of OpenAPI 3.1,
  `tama-operations/1`, documented in `docs/tama-operations-profile.md`.
  - Each operation is `POST /operations/{operationId}`, with a JSON input
    schema, a `200` result schema and an optional `default` error schema.
  - `x-tama-*` extensions carry the source ID, required scopes, the
    destructive flag, any confirmation rule and informational bounds.
  - A pure `Tama.Dex.Profile.validate/1` checks documents, backed by a published
    JSON Schema. Producers can use it in their tests.
- **SQLite index:** `Tama.Dex.Index` is a process the host starts under its own
  supervisor, with an explicit path or an in-memory database.
  - One index holds every cassette, and each cassette is a namespace.
    Operations are addressed by cassette and operation ID, which need only be
    unique within a cassette.
  - Importing a cassette replaces that whole cassette in one transaction.
    Loading a host document replaces one source of a local cassette.
    Reloading unchanged content does nothing, and other cassettes never
    change.
  - The database is derived data. An unknown schema version is recreated
    empty.
- **Search:** FTS5 full-text search with weighted ranking over operation IDs,
  summaries, tags, descriptions and input field names, ranked across every
  cassette, with each result naming its cassette.
  - Caller text is turned into safe term queries.
  - Results include only operations the caller's verified scopes allow. They
    stay within a byte budget and include input schemas when they fit.
- **Execute:**
  - Look up the operation in the cassette the caller names, and re-check the
    caller's scopes. An operation the
    caller can't see is reported as not found.
  - Require the confirmation field and validate the input against the
    compiled schema (JSON Schema 2020-12).
  - Dispatch exactly once to the host's executor for that source, with no
    deadline added by tama-dex, then check the result against the declared
    response schema.
  - Errors say whether the operation was dispatched. An invalid result keeps
    the operation's declared identity values for reconciliation.
  - Nothing is retried, stored or logged.
- **Cassettes:** a portable, read-only SQLite file (`.tama-cassette`). It
  holds a prebuilt index plus the canonical documents it was built from and
  their digests.
  - Producers build one in CI with `mix tama.dex.cassette`, giving it a stable
    name such as `opsmaru_incus`. opsmaru_incus will publish one with every
    release.
  - A host may import several cassettes into one index. A host can rename a
    cassette on import if two names collide.
  - Hosts verify and import it at install or start. Prebuilt rows are copied
    only when the host pins the cassette's SHA-256. Otherwise the index is
    rebuilt from the embedded documents.
  - A cassette built with a different index schema version is rebuilt from
    its documents.
- **MCP tool definitions:** the `search` and `execute` tool definitions
  (name, title, description, input and output schemas) as data, with handler
  functions returning JSON-safe results. Hosts wrap them in their own MCP
  server; for TamaMCP, that is `raw_input_schema`/`raw_output_schema` tools.
- **Project:** a Mix library with exqlite, jsonschex, jason and telemetry, the
  `mix precommit` checks and CI, following the Kritama `tama_mcp` conventions.

## Capabilities

### New Capabilities

- `operation-profile`: the `tama-operations/1` document standard and its
  validation.
- `operation-index`: the host-supervised SQLite index, cassette namespaces and
  loading.
- `operation-search`: scope-filtered full-text search.
- `operation-execute`: validated, single dispatch to host executors.
- `executor-contract`: the `Tama.Dex.Executor` behaviour and `Tama.Dex.Call`
  that host adapters implement.
- `mcp-tools`: the `search`/`execute` tool definitions and handlers for host
  MCP servers.
- `cassette`: building, verifying and importing portable prebuilt index files.

## Impact

- New Hex package `tama_dex`, under Apache-2.0.
- `opsmaru_incus` needs a pure `Operations.openapi/0` that emits a
  `tama-operations/1` document. That is a separate change in that repository,
  and it adds no dependency on tama-dex.
- Macus imports the bundled `opsmaru_incus` cassette and loads its own runtime
  document into a local `macus` cassette at startup, registers its executors, and backs its `search`/`execute` MCP tools
  with these handlers. That unblocks Macus search task 7.6 once tama-dex is
  released.
