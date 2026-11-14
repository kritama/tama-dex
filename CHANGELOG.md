# Changelog

All notable changes to this project will be documented in this file.

The project follows Semantic Versioning and uses Conventional Commits.

## [Unreleased]

### Added

- Added the `:tama_dex` Mix library skeleton. It has no application callback,
  so loading or starting it starts no process, opens no database and creates
  no file.
- Added the `tama-operations/1` profile JSON Schema in `priv/profile/` and
  the pure `Tama.Dex.Profile.validate/1`, which reports every issue with a
  JSON pointer and a stable code, and normalizes a valid document into
  `Tama.Dex.Document` and `Tama.Dex.Operation` structs with a canonical-JSON
  SHA-256 digest and standalone bundled schemas.
- Added the host-supervised `Tama.Dex.Index`, a SQLite index (a file
  created with mode 0600 in WAL mode, or `:memory`) with separate reader
  and writer connections, storage schema version 1 that is recreated empty
  when unknown, and a lazily filled compiled-schema cache.
- Added cassette namespaces with `Tama.Dex.load/3`, `unload/2` and
  `cassettes/1`. A load validates the whole document, replaces one source of
  a local cassette in one transaction, and is a no-op for an unchanged
  digest.
- Added `Tama.Dex.search/3` and `describe/4`: scope-filtered FTS5 search
  across every cassette in one BM25 ranking, with caller text reduced to
  quoted prefix terms that FTS5 tokenizes as it does indexed text, an
  exact `operationId` boosted first, BM25
  statistics taken only from the operations the caller could see, cassette,
  source, tag, deprecated and destructive filters, and responses kept within
  64 KiB by dropping the lowest-ranked input schemas first.
- Added `Tama.Dex.execute/5`, the `Tama.Dex.Executor` behaviour, and the
  `Tama.Dex.Call` and `Tama.Dex.Error` structs. Execute checks visibility,
  the executor registration, the input shape, the confirmation field and the
  input schema before dispatching exactly once with no deadline, validates
  the result against the declared schemas, and marks every error with
  `dispatched`. Inputs and results are never stored, logged or sent in
  telemetry.
- Added `Tama.Dex.MCP`: the `search` and `execute` tool definitions as data,
  with JSON Schema 2020-12 input and output schemas, and `handle_search/3`
  and `handle_execute/4`. Handlers take any caller with a verified `scopes`
  list, return JSON-safe maps matching the output schemas, encode errors as
  `error` objects with a `kind` and `dispatched`, and reject arguments that
  fail the tool schema as `invalid_arguments` before any lookup. The README
  shows a TamaMCP host built from the definitions.
- Added cassettes: `Tama.Dex.Cassette.build/3` and `mix tama.dex.cassette`
  build `tama-cassette/1` files with a manifest, canonical documents and a
  reproducible content digest; `Tama.Dex.Cassette.verify/2` checks an
  untrusted file's size, SHA-256, header, schema objects, integrity,
  document digests and profile validity, all against one in-memory
  snapshot of the file; and `Tama.Dex.import/3` installs a
  cassette under its own name or `as:`, copying prebuilt rows only under a
  matching SHA-256 pin and rebuilding from the documents otherwise.
- Added startup-bounded indexing: a `timeout` for `load/3` and `import/3`
  that rolls back to the previous entries, background imports with
  `async: true`, `Tama.Dex.Index.status/1` with
  `[:tama_dex, :index, :status]` telemetry, per-cassette status in
  `cassettes/1`, and `not_ready` from search, describe, execute and the MCP
  handlers while nothing is committed.
- Added `Tama.Dex.Telemetry`, which documents every event. Span
  `:exception` events carry the exception's module and argument-free
  stacktraces, so no caller data reaches telemetry handlers.
- Added README usage: starting the index, installing documents and
  cassettes, registering executors, search and execute, building a cassette
  and telemetry.

### Performance

Indexing times measured by `bench/import.exs` on a GitHub-hosted
`ubuntu-latest` runner (x86_64, 4 schedulers), Elixir 1.19.5 and OTP 27, at
commit c511505. Times are in milliseconds, the median and slowest of 5 runs.
All are well within the 2 s target for a 1024-operation rebuild. Until an
`opsmaru_incus` release publishes its documents, its row uses the
`opsmaru_incus`-shaped test fixture (4 operations).

| Documents | Operations | Case | Median | Slowest |
| --- | ---: | --- | ---: | ---: |
| Generated | 1024 | load (rebuild) | 454.3 | 504.1 |
| Generated | 1024 | import, unpinned (rebuild) | 434.6 | 446.2 |
| Generated | 1024 | import, pinned (copy) | 350.0 | 353.0 |
| Generated | 1024 | cassette build | 992.8 | 992.8 |
| opsmaru_incus fixture | 4 | load (rebuild) | 2.7 | 2.9 |
| opsmaru_incus fixture | 4 | import, unpinned (rebuild) | 4.4 | 4.9 |
| opsmaru_incus fixture | 4 | import, pinned (copy) | 3.4 | 3.9 |
| opsmaru_incus fixture | 4 | cassette build | 30.0 | 30.0 |
