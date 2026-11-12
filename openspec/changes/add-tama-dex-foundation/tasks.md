# Tasks

## 1. Project

- [ ] 1.1 Create the Mix library `:tama_dex` (module `TamaDex`, version `0.1.0-dev`, Elixir `~> 1.18`, Apache-2.0) with no `mod:` application callback. Add dependencies `exqlite ~> 0.43`, `jsonschex ~> 0.11`, `jason ~> 1.4` and `telemetry ~> 1.3`, plus dev/test `credo`, `dialyxir` and `ex_doc`. Add the `precommit` alias and `cli` preferred env, matching `tama_mcp` (format check, warnings as errors, Credo strict, `test --cover`), and the Dialyzer and docs config. Ship only `lib`, `priv/profile`, `docs/tama-operations-profile.md`, `mix.exs`, `README.md`, `CHANGELOG.md` and `LICENSE` in the package. Confirm `mise run check` passes.
- [ ] 1.2 Add a test that starts the `:tama_dex` application and asserts it creates no process, ETS table or file.
- [ ] 1.3 Add `.github/workflows/ci.yml` modeled on `tama_mcp`: pull requests, `develop` pushes and dispatch; `contents: read`; actions pinned by commit SHA; Elixir 1.18.x and 1.19.5 on OTP 27.3.4.16; `hex.audit`, `precommit`, Dialyzer PLT and check, `docs`, `hex.build`; and strict OpenSpec validation through mise. Lint it with actionlint.

## 2. Profile

- [ ] 2.1 Write `priv/profile/tama-operations-1.schema.json` (JSON Schema 2020-12) for the document shape in `docs/tama-operations-profile.md`, and keep the two in agreement.
- [ ] 2.2 Implement the pure `TamaDex.Profile.validate/1` (design Decision 2). It runs JSON Schema shape validation, then the semantic rules: path suffix equals `operationId`, IDs unique, confirmation field is a required string property, `$ref`s internal and resolvable (bundled as `$defs`), every schema compiles with jsonschex, opaque extensions within 16 KiB, `x-tama-identity` names declared by the `200`/`default` schema, size and count limits, and unknown `x-tama-*` keys rejected. It returns all issues with pointer, code and a bounded message. It normalizes to `TamaDex.Document` and `TamaDex.Operation` structs and computes the canonical-JSON SHA-256 digest.
- [ ] 2.3 Add fixtures under `test/fixtures/profile/`: one valid document shaped like `opsmaru_incus` (read, write, exec and destructive-with-confirmation operations, a `default` error schema and `x-opsmaru-requires`) and one invalid document per rule in the operation-profile spec. Test every scenario, including that several defects are reported together.

## 3. Index

- [ ] 3.1 Implement `TamaDex.Index` (design Decisions 1 and 4).
  - `start_link/1` takes a required `path` (file or `:memory`), an optional `name` and limits.
  - A database file is created with mode 0600, in WAL mode, with foreign keys on.
  - Schema version 1 is created on first open. Any other version is dropped and recreated, emitting `[:tama_dex, :index, :recreated]`.
  - The compiled-schema ETS cache is rebuilt from stored schemas on open.
- [ ] 3.2 Implement `TamaDex.load/2`, `unload/2` and `sources/1` (Decision 3).
  - Validate first.
  - An unchanged digest is a no-op returning `changed: false`.
  - Replace the source in one transaction, failing `duplicate_operation` on IDs owned by another source.
  - Swap cache entries only after commit, so a failed load keeps prior entries.
- [ ] 3.3 Test every operation-index scenario, including concurrent readers during a reload (no mixed view), a restart on the same file, and an older schema version being recreated.

## 4. Search

- [ ] 4.1 Implement `TamaDex.search/3` and `describe/3` (Decision 5).
  - `scopes` is required.
  - Caller text becomes quoted prefix terms joined with AND. Raw FTS5 syntax never reaches SQLite.
  - Rank with weighted bm25, boosting an exact `operationId` match first. An empty query lists in ID order.
  - Filters: `source`, `tags`, `include_deprecated` and `include_destructive`.
  - `limit` defaults to 5, maximum 20. Descriptions truncate at 1024 characters with a flag.
  - Keep within the 64 KiB budget, dropping schemas from the lowest-ranked results first.
- [ ] 4.2 Test every operation-search scenario, including injection strings (`"`, `NEAR`, `*`, `:`, `-`, `OR`, unbalanced parentheses), hidden operations never affecting counts or flags, field-name matches, and budget trimming.

## 5. Execute

- [ ] 5.1 Implement `TamaDex.execute/4` and `TamaDex.Error` (Decision 6). Checks run in order: visibility (`not_found`), executor (`no_executor`), input (`invalid_input`), then confirmation (`confirmation_required`). Dispatch exactly once, with no tama-dex deadline, catching raises, exits and throws as `dispatch_failed`. Validate the result against `200`/`default` (`invalid_output`, carrying only the declared `x-tama-identity` values). Set `dispatched` on every error. Never retry, store or log inputs or results.
- [ ] 5.2 Test every operation-execute scenario with a counting executor, proving that rejected calls never reach it and that a raising executor is called exactly once. Also check `dispatched` on every error kind, the identity values on `invalid_output`, and that a slow executor is never cut off by tama-dex. Capture logs and telemetry in an execute test to assert that input and result values never appear.

## 6. MCP tools

- [ ] 6.1 Implement `TamaDex.MCP.search_tool/0`, `execute_tool/0`, `handle_search/3` and `handle_execute/4` (Decision 7). Schemas reject unknown properties. Arguments that fail a tool schema return `invalid_arguments` before any lookup. Handlers use only the caller's verified scopes.
- [ ] 6.2 Add a README section and a test showing a TamaMCP host's two tool modules built from these definitions with `raw_input_schema`/`raw_output_schema`. Use `tama_mcp` as a test-only dependency, or an equivalent schema-identity test if that would create a cycle.

## 7. Cassettes

- [ ] 7.1 Implement `TamaDex.Cassette.build/2` and the `mix tama_dex.cassette` task (design Decision 9). It takes `--document Mod.fun` and `--file` inputs and an `--output`, validates, rejects duplicates, writes the manifest and canonical documents, runs `VACUUM`, renames atomically, and prints the content digest and file SHA-256.
- [ ] 7.2 Implement `TamaDex.Cassette.verify/2`: size limit, optional SHA-256, read-only open with extensions off, an exact `sqlite_master` allowlist with no triggers or views, the manifest format, document and content digests, and profile validation of every document.
- [ ] 7.3 Implement `TamaDex.import/3`. Copy mode applies only with a matching pin and the same index schema version. Every other case uses rebuild mode. Both use per-source atomic replacement and duplicate rules, rebuild the compiled schemas, and report the mode and `changed` for each source.
- [ ] 7.4 Test every cassette scenario: a build from module functions and files; the same documents giving the same content digest; tampered rows without a pin rebuilt from documents; a wrong pin rejected; an altered embedded document rejected; triggers and views rejected; an older index schema imported in rebuild mode; and an oversized file rejected before opening.

## 8. Telemetry, documentation and release readiness

- [ ] 8.1 Emit the load, search and execute `:start`/`:stop`/`:exception` events and the index `:recreated` event, with metadata limited as in Decision 8. Test that the metadata holds no query text, inputs, results or schemas.
- [ ] 8.2 Write the README usage (start the index, load documents, register executors, wire the two tools), add `CHANGELOG.md`, write module docs for every public module, and run `mix docs` without warnings.
- [ ] 8.3 Add a release workflow modeled on `tama_mcp`'s `release.yml`. It publishes only from `main`, in the `hex` environment, with `HEX_API_KEY`. Running a release needs user authorization.

## 9. Producer evidence

- [ ] 9.1 Once `opsmaru_incus` publishes `Operations.openapi/0`, add a test-only dependency and a test that its document validates, loads, and that a representative search and a stubbed execute (one read and one destructive with confirmation) behave as specified. Also import the cassette attached to that opsmaru_incus GitHub Release, pinned by its published SHA-256. Leave this task open until that release exists, and record the version used.
