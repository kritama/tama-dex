# Project instructions

tama-dex is a pure Elixir library (`:tama_dex`). It ingests operation documents
in the **Tama operations profile** of OpenAPI 3.1 (`tama-operations/1`, defined
in `docs/tama-operations-profile.md`), indexes them in SQLite, and provides
scope-filtered `search` and validated `execute` for hosts whose MCP server
exposes only those two tools. Producers such as `opsmaru_incus` and Macus
publish profile documents; hosts such as Macus load them and own the MCP
server.

## Library boundary

- Do not add an application callback. Loading or starting the dependency must
  not open a database, create files, start processes, or fetch anything. The
  host starts `Tama.Dex.Index` under its own supervisor, with an explicit
  database path, and passes the index into every call.
- Do not add HTTP endpoints, listeners, Phoenix, Ecto, Plug servers, an MCP
  server, or network fetching of documents or cassettes. Hosts pass documents
  as data and cassettes as local files.
- Treat cassettes as untrusted until verified. Copy prebuilt rows only under a
  host-supplied SHA-256 pin. Otherwise rebuild from the embedded documents
  after checking their digests.
- Do not depend on `tama_mcp`, `opsmaru_incus` or Macus. tama-dex supplies
  the `search`/`execute` tool definitions as data, plus handler functions. The
  host's MCP server wraps them.
- tama-dex never performs an operation itself. `execute` validates the call
  and then hands it to an executor that the host registers for the operation's
  source: a host adapter module implementing `Tama.Dex.Executor`. Producers
  never need tama_dex to be executable; keep indexing a data contract. Never retry or replay a dispatched call, because the operation may
  already have been accepted.
- Search visibility is not authorization. `execute` re-checks the caller's
  verified scopes against the operation's scopes on every call.

## Contracts

- The profile is a versioned contract with its producers. Change
  `tama-operations/1` only by defining a new profile version, coordinated with
  `opsmaru_incus` and Macus. Keep the profile document, its JSON Schema in
  `priv/profile/` and the validator in agreement.
- The SQLite index is derived data. Profile documents are the source of truth.
  A database whose schema version this code doesn't know is recreated empty,
  never migrated in place.
- Never store, index, log or emit `execute` inputs or results. Keep search
  results, errors, logs and telemetry bounded and free of secrets.

## Workflow

Use OpenSpec for substantial behaviour changes, and validate the plan before
implementing. Development tools are pinned in `mise.toml`. Run `mise trust`
and `mise install` once. Use `mise exec -- openspec ...` in shells without
mise activation. `mise run spec:validate` runs strict OpenSpec validation.
Once the Mix project exists, `mise run check` runs `mix precommit` (format,
warnings as errors, Credo strict, tests with coverage) plus strict validation.
Run Dialyzer and `mix docs` when public types or documentation change.

Use Git Flow with Conventional Commits:
- `develop` is the default and integration branch, and `main` is released
  history.
- `feature/*` and `fix/*` branches start from `develop`.
- `release/*` branches start from `develop` and finish into `main` and then
  `develop`.
- `hotfix/*` branches start from `main`.

Publish work on its feature branch. Hex is the only distribution route. Do not
finish or merge branches, create tags or publish packages without user
authorization.

Every pull request opened by a bot or automated agent must be created as a
draft (for example, `gh pr create --draft`) and remain a draft until a human
marks it ready for review. Bots and agents must never mark any pull request
ready for review, including after checks pass or when asked to prepare it for
review. Only a human may perform that transition. If an agent mistakenly opens
a non-draft pull request, it must convert it back to draft. A later human
decision to mark it ready must be respected.

Never commit `_build`, `deps`, SQLite databases, `.integration/` or secrets.
