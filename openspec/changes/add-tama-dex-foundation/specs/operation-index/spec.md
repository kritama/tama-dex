# Spec Delta

## ADDED Requirements

### Requirement: Host-supervised index

The library SHALL have no application callback.

- Loading or starting the `:tama_dex` dependency MUST NOT open a database,
  create files, start processes or fetch anything.
- A host SHALL start `TamaDex.Index` explicitly, under its own supervisor,
  with a required `path` (a file path, or `:memory`).
- A database file MUST be created with mode 0600 and opened in WAL mode.
- One index process SHALL own the connection and serialize writes.

#### Scenario: Dependency loaded without an index

- **WHEN** a host compiles and starts its application with `:tama_dex` as a dependency but never starts an index
- **THEN** no process, file or database is created by tama-dex

#### Scenario: Missing path

- **WHEN** `TamaDex.Index.start_link/1` is called without `path`
- **THEN** it fails to start with an argument error, and creates nothing

### Requirement: Per-source loading

`TamaDex.load/2` SHALL validate a whole profile document before writing.

- It SHALL replace every entry of that document's source in a single
  transaction.
- Reloading a document with the same canonical-JSON SHA-256 digest SHALL change
  nothing and report `changed: false`.
- An `operationId` already owned by another source MUST make the whole load
  fail, naming the conflicting IDs and source, with no change.
- A failed load MUST leave the source's previous entries and compiled schemas
  in place.
- `TamaDex.unload/2` SHALL remove one source's entries.
- `TamaDex.sources/1` SHALL report each source's title, version, profile,
  digest, operation count and load time.

#### Scenario: Source replaced atomically

- **WHEN** a host loads a new version of the `opsmaru_incus` document that drops one operation and adds another
- **THEN** after the call, search and execute see exactly the new set, and no reader observes a mixture

#### Scenario: Duplicate operation across sources

- **WHEN** the `macus` document declares an `operationId` already loaded from `opsmaru_incus`
- **THEN** the load fails with `duplicate_operation`, naming the ID and `opsmaru_incus`, and both sources keep their entries

#### Scenario: Unchanged reload

- **WHEN** the same document is loaded twice
- **THEN** the second call reports `changed: false` and performs no write

### Requirement: Startup-bounded indexing and readiness

- `TamaDex.load/3` and `TamaDex.import/3` SHALL accept a `timeout`. On expiry
  they SHALL roll back the source transaction, keep the previous entries and
  return `{:error, :deadline}`.
- `import/3` with `async: true` SHALL return after the size and SHA-256
  checks, and finish in the index process.
- `TamaDex.Index.status/1` SHALL report `:empty`, importing progress, `:ready`
  or a failure.
- While no source has been committed and indexing is in progress, `search`,
  `describe` and `execute` SHALL return `not_ready` with `dispatched: false`,
  without blocking.
- A source being reloaded SHALL keep serving its previous entries until its
  new entries commit.

#### Scenario: Deadline during rebuild

- **WHEN** a rebuild import exceeds its `timeout`
- **THEN** it returns `{:error, :deadline}`, and the index holds exactly its previous sources

#### Scenario: Background import at host startup

- **WHEN** a host starts the index, calls `import` with `async: true` and immediately serves a search
- **THEN** the call returns at once, the search returns `not_ready` until the import commits, and the host's startup is not blocked

#### Scenario: Reload keeps serving

- **WHEN** a source is re-imported in the background while callers search it
- **THEN** they keep receiving the previous entries until the new ones commit

### Requirement: Derived, versioned storage

The SQLite database SHALL be treated as derived data.

- It SHALL record its schema version.
- On open, a database with a missing or different schema version SHALL be
  recreated empty. That emits a recreation telemetry event, after which the
  host reloads its documents.
- The index MUST NOT migrate in place, and MUST NOT write a schema version it
  doesn't know.

#### Scenario: Older index file

- **WHEN** a host opens a database written by an older schema version
- **THEN** every table is recreated empty, `[:tama_dex, :index, :recreated]` is emitted, and `TamaDex.sources/1` returns an empty list

### Requirement: Index persistence

A file-backed index SHALL keep its loaded sources across restarts of the index
process and of the host.

#### Scenario: Host restart

- **WHEN** a host restarts and opens the same database path without loading documents
- **THEN** previously loaded sources are searchable, and the compiled schemas are rebuilt from the stored schemas before the first execute
