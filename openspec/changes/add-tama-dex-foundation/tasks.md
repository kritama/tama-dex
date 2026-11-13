# Tasks

## 1. Project

- [x] 1.1 Create the Mix library `:tama_dex` (root module `Tama.Dex` in `lib/tama/dex.ex`, every module under `Tama.Dex.*`, version `0.1.0-dev`, Elixir `~> 1.18`, Apache-2.0) with no `mod:` application callback. Add dependencies `exqlite ~> 0.43`, `jsonschex ~> 0.11.2` (the latest; a tama_mcp release must move to it before a host can depend on both), `jason ~> 1.4` and `telemetry ~> 1.3`, plus dev/test `credo`, `dialyxir` and `ex_doc`. Add the `precommit` alias and `cli` preferred env, matching `tama_mcp` (format check, warnings as errors, Credo strict, `test --cover`), and the Dialyzer and docs config. Ship only `lib`, `priv/profile`, `docs/tama-operations-profile.md`, `mix.exs`, `README.md`, `CHANGELOG.md` and `LICENSE` in the package. Confirm `mise run check` passes.
- [x] 1.2 Add a test that starts the `:tama_dex` application and asserts it creates no process, ETS table or file.
- [x] 1.3 Add `.github/workflows/ci.yml` modeled on `tama_mcp`: pull requests, `develop` pushes and dispatch; `contents: read`; actions pinned by commit SHA; Elixir 1.18.x and 1.19.5 on OTP 27.3.4.16; `hex.audit`, `precommit`, Dialyzer PLT and check, `docs`, `hex.build`; and strict OpenSpec validation through mise. Lint it with actionlint.

## 2. Profile

- [x] 2.1 Write `priv/profile/tama-operations-1.schema.json` (JSON Schema 2020-12) for the document shape in `docs/tama-operations-profile.md`, and keep the two in agreement.
- [x] 2.2 Implement the pure `Tama.Dex.Profile.validate/1` (design Decision 2). It runs JSON Schema shape validation, then the semantic rules: path suffix equals `operationId`, IDs unique, confirmation field is a required top-level string property (read through a top-level `$ref`, never inside compositions), `$ref`s internal and resolvable (bundled as `$defs`), every schema compiles with jsonschex, opaque extensions within 16 KiB, `x-tama-identity` names declared by the `200`/`default` schema, size and count limits, and unknown `x-tama-*` keys rejected. It returns all issues with pointer, code and a bounded message. It normalizes to `Tama.Dex.Document` and `Tama.Dex.Operation` structs and computes the canonical-JSON SHA-256 digest.
- [x] 2.3 Add fixtures under `test/fixtures/profile/`: one valid document shaped like `opsmaru_incus` (read, write, exec and destructive-with-confirmation operations, a `default` error schema and `x-opsmaru-requires`) and one invalid document per rule in the operation-profile spec. Test every scenario, including that several defects are reported together (asserting that the expected issues are included, not an exact count). The size-limit cases (document, operation count, schema and extension size) are built in the tests rather than checked in as large files.

## 3. Index

- [x] 3.1 Implement `Tama.Dex.Index` (design Decisions 1 and 4, with the `cassettes`, `sources` and `operations` tables keyed by cassette), with separate read and write connections, the writer running in a linked process, and an in-memory database for `:memory` opened through the `memdb` VFS under a name unique to the index. First confirm that exqlite 0.43 opens URI filenames (`mode=ro`, `vfs=memdb`).
  - `start_link/1` takes a required `path` (file or `:memory`), an optional `name` and limits.
  - A database file is created with mode 0600, in WAL mode, with foreign keys on.
  - Schema version 1 is created on first open. Any other version is dropped and recreated, emitting `[:tama_dex, :index, :recreated]`.
  - Compiled schemas are cached lazily, on first execute, in a public ETS table keyed by the SHA-256 of the stored schema text. Opening compiles nothing, and entries no row references are dropped after each commit or unload.
- [x] 3.2 Implement cassette namespaces and `Tama.Dex.load/3`, `unload/2` and `cassettes/1` (Decision 3).
  - Validate cassette names, and fail `cassette_conflict` when a name is held by the other kind.
  - `load/3` requires `cassette:` and validates first. An unchanged digest is a no-op returning `changed: false`.
  - Replace the source in one transaction, failing `duplicate_operation` on IDs owned by another source of the same cassette. The same IDs in other cassettes are allowed.
  - A failed load leaves the source's rows, and so the schemas it executes with, unchanged.
- [x] 3.3 Test every operation-index scenario, including the same operation name in two cassettes, a change to one cassette leaving the others untouched, concurrent readers during a reload (no mixed view, in both file-backed and `:memory` indexes), a restart on the same file, and an older schema version being recreated.

## 4. Search

- [x] 4.1 Implement `Tama.Dex.search/3` and `describe/4` (Decision 5), ranking all cassettes together in the one FTS table.
  - `scopes` is required.
  - Caller text becomes quoted prefix terms joined with AND. Raw FTS5 syntax never reaches SQLite.
  - Rank with weighted bm25, boosting an exact `operationId` match first, then order ties by cassette and ID. An empty query lists in `(cassette, operationId)` order.
  - Filters: `cassette`, `source`, `tags`, `include_deprecated` and `include_destructive`. Results carry `cassette` and `cassette_version`.
  - `limit` defaults to 5; outside 1–20 raises `ArgumentError`. Query text over 512 bytes raises `ArgumentError`, and text with no terms is an empty query. Descriptions truncate at 1024 characters with a flag.
  - Keep within the 64 KiB budget, dropping schemas from the lowest-ranked results first.
- [x] 4.2 Test every operation-search scenario, including results from two cassettes in one ranking, the cassette filter, injection strings (`"`, `NEAR`, `*`, `:`, `-`, `OR`, unbalanced parentheses), hidden operations never affecting counts or flags, field-name matches, punctuation-only and over-long queries, out-of-range limits, and budget trimming.

## 5. Execute

- [x] 5.1 Implement `Tama.Dex.execute/5` and `Tama.Dex.Error` (Decision 6). It requires the cassette and looks only there. Checks run in order: visibility (`not_found`, also for unknown cassettes; `not_ready` for a cassette still on its first import), executor (`no_executor`), input shape (a JSON object with string keys, within 1 MiB, `invalid_input`), confirmation (`confirmation_required`), then the input schema (`invalid_input`). Dispatch exactly once, with no tama-dex deadline, catching raises, exits and throws as `dispatch_failed`. Validate the result against `200`/`default` (`invalid_output`, carrying only the declared `x-tama-identity` values); any return other than `{:ok, map}`/`{:error, map}` with a JSON-encodable map is also `invalid_output`. Return the executor's own valid error as `{:error, %{cassette, operation_id, source, operation_error}}`. Set `dispatched` on every error. Never retry, store or log inputs or results.
- [x] 5.2 Test every operation-execute scenario with a counting executor module, including an operation name present only in another cassette, a missing confirmation reported as `confirmation_required` even when the rest of the input is also invalid, proving that rejected calls never reach it and that a raising executor is called exactly once. Also check `dispatched` on every error kind, an unexpected executor return value, an operation error told apart from a tama-dex error, the identity values on `invalid_output`, and that a slow executor is never cut off by tama-dex. Capture logs and telemetry in an execute test to assert that input and result values never appear.

- [x] 5.3 Implement the `Tama.Dex.Executor` behaviour and the `Tama.Dex.Call` struct (design Decision 11, `executor-contract` spec). Accept `module` or `{module, opts}` registrations, returning `no_executor` for missing entries and for modules without `execute/2`. Pass the verified scopes, cassette, source, operation ID, host context and opts in the call. Test every executor-contract scenario, including a host adapter module that compiles a fake producer without tama_dex.

## 6. MCP tools

- [x] 6.1 Implement `Tama.Dex.MCP.search_tool/0`, `execute_tool/0`, `handle_search/3` and `handle_execute/4` (Decision 7). `search` accepts an optional `cassette`; `execute` requires `cassette`, `operation_id` and `input`. Schemas reject unknown properties. Arguments that fail a tool schema return `invalid_arguments` before any lookup. Handlers use only the caller's verified scopes. A caller is any map or struct with a `scopes` list (for example `TamaMCP.Context`); without one, raise `ArgumentError`.
- [x] 6.2 Add a README section and a test showing a TamaMCP host's two tool modules built from these definitions with `raw_input_schema`/`raw_output_schema`. Do not add `tama_mcp`, even as a test dependency: test schema identity with a host-style module built from the definitions.

## 7. Cassettes

- [ ] 7.1 Implement `Tama.Dex.Cassette.build/3` and the `mix tama.dex.cassette` task (`Mix.Tasks.Tama.Dex.Cassette`, design Decision 9). It takes a required `--name` and `--version`, `--document Mod.fun` and `--file` inputs and an `--output`, validates, rejects duplicate sources and IDs within the cassette, writes the manifest and canonical documents, runs `VACUUM`, renames atomically, and prints the content digest and file SHA-256.
- [ ] 7.2 Implement `Tama.Dex.Cassette.verify/2`: size limit, optional SHA-256, read-only open with extensions off, an exact `sqlite_master` allowlist with no triggers or views, the manifest format, document and content digests, and profile validation of every document.
- [ ] 7.3 Implement `Tama.Dex.import/3`. It installs under the manifest name or `as:`, and replaces the whole cassette in one transaction without touching others. Copy mode applies only with a matching pin and the same index schema version, rewriting the `cassette` column to the installed name and giving the copied rows, and their FTS rows, new `operations.id` values. A different tama-dex version alone never forces rebuild mode. Every other case uses rebuild mode. Neither compiles schemas; they are compiled on first execute. An unchanged content digest is a no-op. Report the cassette, version, mode, `changed` and sources.
- [ ] 7.4 Implement design Decision 10: `timeout` for `load/3` and `import/3` with rollback; `async: true` import returning `{:ok, ref}` and sending `{:tama_dex_import, ref, result}` when done; no default call timeout when `timeout` is absent; `Tama.Dex.Index.status/1` (`:ready` whenever a cassette is committed) with progress and `[:tama_dex, :index, :status]` telemetry, and per-cassette status in `cassettes/1`; and `not_ready` (`{:error, :not_ready}` from `search`/`describe`, a `not_ready` error from `execute`, an `error` object from the MCP handlers) only while nothing is committed, plus from `describe`/`execute` for a cassette still on its first import. Test the deadline, background import, waiting for a background import, status with one cassette failed, second-cassette-still-importing, reload-keeps-serving, in-memory reload and not-ready scenarios.
- [ ] 7.5 Test every cassette scenario: a build from module functions and files; several cassettes in one index; an upgrade dropping an operation; an `as:` rename on a name collision; the same documents giving the same content digest; tampered rows without a pin rebuilt from documents; a wrong pin rejected; an altered embedded document rejected; triggers and views rejected; an older index schema imported in rebuild mode; and an oversized file rejected before opening. Build every cassette under test in a temporary directory, and commit none.

## 8. Telemetry, documentation and release readiness

- [ ] 8.1 Emit the load, import, search and execute `:start`/`:stop`/`:exception` events and the index `:recreated` and `:status` events, with metadata limited as in Decision 8. Test that the metadata holds no query text, inputs, results, schemas or file paths.
- [ ] 8.2 Write the README usage (start the index, load documents, register executors, wire the two tools), add `CHANGELOG.md`, write module docs for every public module, and run `mix docs` without warnings.
- [ ] 8.3 Add a release workflow modeled on `tama_mcp`'s `release.yml`. It publishes only from `main`, in the `hex` environment, with `HEX_API_KEY`. Running a release needs user authorization.
- [ ] 8.4 Measure and record, in the changelog, rebuild and copy-mode import times for a 1024-operation fixture and for the opsmaru_incus documents on a GitHub-hosted runner, against the 2 s target in Decision 10.

## 9. Producer evidence

- [ ] 9.1 Once an `opsmaru_incus` release publishes its profile documents and cassette, check in, under `test/fixtures/producers/opsmaru_incus/<version>/`, its composite document and a small sample of its native document (one read, one write and one destructive-with-confirmation operation, cut from the published JSON and recorded with the source version; the sample keeps every `components.schemas` entry its operations reference and must validate on its own), with no dependency on `opsmaru_incus`. Don't check in the full native document, which grows with the catalogue. The sample's digest differs from the released document's, so it is not compared with the release cassette. Test that both validate and load into one cassette, and that a representative search and a stubbed execute (one read and one destructive with confirmation) behave as specified. Add an `:integration`-tagged test, excluded by default, that imports the full cassette attached to that GitHub Release from `.integration/`, pinned by its published SHA-256, and skips when the file is absent. Never commit the cassette. Leave this task open until that release exists, and record the version used.
