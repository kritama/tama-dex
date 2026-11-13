# Spec Delta

## ADDED Requirements

### Requirement: Host-supervised index

The library SHALL have no application callback.

- Loading or starting the `:tama_dex` dependency MUST NOT open a database,
  create files, start processes or fetch anything.
- A host SHALL start `Tama.Dex.Index` explicitly, under its own supervisor,
  with a required `path` (a file path, or `:memory`).
- A database file MUST be created with mode 0600 and opened in WAL mode.
- One index process SHALL own the connections and serialize writes.
- One index SHALL hold every cassette the host installs.

#### Scenario: Dependency loaded without an index

- **WHEN** a host compiles and starts its application with `:tama_dex` as a dependency but never starts an index
- **THEN** no process, file or database is created by tama-dex

#### Scenario: Missing path

- **WHEN** `Tama.Dex.Index.start_link/1` is called without `path`
- **THEN** it fails to start with an argument error, and creates nothing

### Requirement: Cassette namespaces

Every source in an index SHALL belong to exactly one cassette, which is its
namespace.

- A cassette name SHALL match `^[a-z][a-z0-9_]{0,63}$`.
- Source IDs and `operationId`s SHALL be unique within a cassette. They MAY
  repeat across cassettes.
- Operations SHALL be addressed by `(cassette, operation_id)`.
- A cassette SHALL be either imported (from a cassette file) or local (built
  by `load/3`). Loading into an imported cassette's name, or importing over a
  local cassette's name, MUST fail with `cassette_conflict` and change
  nothing.
- Changes to one cassette MUST NOT alter any other cassette.
- `Tama.Dex.unload/2` SHALL remove one cassette.
- `Tama.Dex.cassettes/1` SHALL report each cassette's name, kind, version,
  status, import mode, digest, load time and sources (title, version,
  profile, digest and operation count).

#### Scenario: Same operation name in two cassettes

- **WHEN** the `macus` cassette and the `opsmaru_incus` cassette both declare `list_instances`
- **THEN** both are installed, and each is addressed by its own cassette name

#### Scenario: Name held by the other kind

- **WHEN** a host calls `load/3` with `cassette: "opsmaru_incus"` while `opsmaru_incus` is an imported cassette
- **THEN** the load fails with `cassette_conflict`, and the imported cassette is unchanged

### Requirement: Local cassette loading

`Tama.Dex.load/3` SHALL validate a whole profile document before writing, and
install it as one source of the local cassette named by its required
`cassette` option.

- It SHALL replace every entry of that source in a single transaction.
- Reloading a document with the same canonical-JSON SHA-256 digest SHALL change
  nothing and report `changed: false`.
- An `operationId` already owned by another source of the same cassette MUST
  make the whole load fail, naming the conflicting IDs and source, with no
  change.
- A failed load MUST leave the source's previous entries and compiled schemas
  in place.

#### Scenario: Source replaced atomically

- **WHEN** a host loads a new version of the `macus` runtime document that drops one operation and adds another
- **THEN** after the call, search and execute see exactly the new set, and no reader observes a mixture

#### Scenario: Duplicate operation within a cassette

- **WHEN** a second document loaded into the local `macus` cassette declares an `operationId` already owned by another of its sources
- **THEN** the load fails with `duplicate_operation`, naming the ID and the owning source, and the cassette keeps its entries

#### Scenario: Unchanged reload

- **WHEN** the same document is loaded twice into the same cassette
- **THEN** the second call reports `changed: false` and performs no write

### Requirement: Startup-bounded indexing and readiness

- `Tama.Dex.load/3` and `Tama.Dex.import/3` SHALL accept a `timeout`. On expiry
  they SHALL roll back the source transaction, keep the previous entries and
  return `{:error, :deadline}`.
- Without a `timeout`, they SHALL wait until the work finishes, and MUST NOT
  fail on a default call timeout.
- `import/3` with `async: true` SHALL return `{:ok, ref}` after the size and
  SHA-256 checks, finish in the index's writer, and then send the caller
  `{:tama_dex_import, ref, result}`.
- `Tama.Dex.Index.status/1` SHALL report `:ready` whenever at least one
  cassette is committed. Otherwise it SHALL report importing progress while a
  load or import runs, a failure if the last attempt failed, or `:empty`.
- `Tama.Dex.cassettes/1` SHALL report each cassette's own status.
- While no cassette has been committed and indexing is in progress, `search`
  and `describe` SHALL return `{:error, :not_ready}`, and `execute` SHALL
  return a `not_ready` error with `dispatched: false`, without blocking.
  `describe` and `execute` SHALL also do so for a cassette whose first import
  is still running.
- Each change of `Tama.Dex.Index.status/1` SHALL emit
  `[:tama_dex, :index, :status]` telemetry.
- In a file-backed index, a cassette being re-imported, or a source being
  reloaded, SHALL keep serving its previous entries until its new entries
  commit.
- In an in-memory index, a read issued during a write MAY wait for that write
  to commit instead of reading the previous entries. It MUST NOT observe a
  mixture of old and new entries.

#### Scenario: Deadline during rebuild

- **WHEN** a rebuild import exceeds its `timeout`
- **THEN** it returns `{:error, :deadline}`, and the index holds exactly its previous cassettes

#### Scenario: Background import at host startup

- **WHEN** a host starts the index, calls `import` with `async: true` and immediately serves a search
- **THEN** the call returns at once, the search returns `not_ready` until the import commits, and the host's startup is not blocked

#### Scenario: Second cassette still importing

- **WHEN** a host imports `opsmaru_incus` and then `macus` in the background, and a caller searches after only `opsmaru_incus` has committed
- **THEN** the search returns `opsmaru_incus` results, `cassettes/1` reports `macus` as importing, and executing a `macus` operation returns `not_ready`

#### Scenario: Waiting for a background import

- **WHEN** a host calls `import` with `async: true` and receives `{:ok, ref}`
- **THEN** it later receives `{:tama_dex_import, ref, result}`, where `result` is what a synchronous import would have returned

#### Scenario: Status with one cassette failed

- **WHEN** `opsmaru_incus` has committed and a later `macus` import fails
- **THEN** `status/1` reports `:ready`, and `cassettes/1` reports the `macus` failure

#### Scenario: Reload keeps serving

- **WHEN** a cassette in a file-backed index is re-imported in the background while callers search it
- **THEN** they keep receiving the previous entries until the new ones commit

#### Scenario: In-memory reload

- **WHEN** a cassette in a `:memory` index is re-imported while callers search it
- **THEN** each search returns either the previous entries or the new ones, never a mixture, and may wait for the commit

### Requirement: Derived, versioned storage

The SQLite database SHALL be treated as derived data.

- It SHALL record its schema version. The version SHALL cover both the table
  definitions and how rows are derived from documents, so a change to either
  uses a new version.
- On open, a database with a missing or different schema version SHALL be
  recreated empty. That emits a recreation telemetry event, after which the
  host reloads its documents.
- The index MUST NOT migrate in place, and MUST NOT write a schema version it
  doesn't know.

#### Scenario: Older index file

- **WHEN** a host opens a database written by an older schema version
- **THEN** every table is recreated empty, `[:tama_dex, :index, :recreated]` is emitted, and `Tama.Dex.cassettes/1` returns an empty list

### Requirement: Index persistence

A file-backed index SHALL keep its cassettes across restarts of the index
process and of the host.

#### Scenario: Host restart

- **WHEN** a host restarts and opens the same database path without loading documents
- **THEN** previously installed cassettes are searchable and executable without reloading, opening the index compiles no schema, and each operation's schemas are compiled from the stored schemas on its first execute
