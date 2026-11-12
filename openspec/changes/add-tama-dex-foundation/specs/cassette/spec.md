# Spec Delta

## ADDED Requirements

### Requirement: Cassette build

`TamaDex.Cassette.build/2` and `mix tama_dex.cassette` SHALL build a
`tama-cassette/1` file from one or more profile documents, given as zero-arity
functions or JSON files.

- Every document SHALL be validated, and IDs duplicated across documents SHALL
  be rejected before writing.
- The file SHALL hold the version 1 index tables, a manifest (format,
  tama-dex version, index schema version, SQLite version, profile, content
  digest) and each source's canonical document with its digest.
- It MUST NOT store wall-clock time.
- It SHALL be written to a temporary file and renamed into place.
- The task SHALL print the content digest and the file's SHA-256.

#### Scenario: Producer CI build

- **WHEN** a producer's CI runs `mix tama_dex.cassette --document Opsmaru.Incus.Operations.openapi --document Opsmaru.Incus.NativeOperations.openapi --output opsmaru_incus-0.2.0.tama-cassette`
- **THEN** one cassette holding both sources is written, and its content digest and SHA-256 are printed

#### Scenario: Reproducible content

- **WHEN** the same documents are built twice with the same tama-dex version
- **THEN** both cassettes have the same content digest

### Requirement: Cassette verification

`TamaDex.Cassette.verify/2` SHALL treat a cassette as untrusted input. It
SHALL:
- reject files over 64 MiB before opening;
- check the file's SHA-256 when the host gives one;
- open the file read-only with extension loading disabled;
- require `sqlite_master` to contain exactly the expected tables, indexes and
  FTS shadow tables, with no triggers or views;
- check the manifest format;
- recompute every embedded document's digest and the content digest;
- validate every embedded document against the profile.

#### Scenario: Altered document

- **WHEN** an embedded document no longer matches its recorded digest
- **THEN** verification fails, and nothing is imported

#### Scenario: Trigger in cassette

- **WHEN** a cassette contains a trigger or view
- **THEN** verification fails before any row is read

### Requirement: Cassette import

`TamaDex.import/3` SHALL verify a cassette, then install each of its sources
with the per-source atomic replacement and duplicate rules of `load/2`.

- It SHALL copy prebuilt rows only when the host supplied a matching SHA-256
  pin and the cassette's index schema version equals the index's.
- In every other case it SHALL rebuild from the embedded documents.
- It SHALL report, for each source, whether it changed and which mode was used.
- It SHALL honour the `timeout` and `async` options of the startup-bounded
  indexing requirement.
- tama-dex MUST NOT download cassettes. Hosts supply local files.

#### Scenario: Pinned release cassette

- **WHEN** Macus imports `opsmaru_incus-0.2.0.tama-cassette` with the SHA-256 published for that release
- **THEN** both sources are installed in copy mode and are searchable immediately

#### Scenario: Unpinned cassette with tampered rows

- **WHEN** a cassette's operation rows grant different scopes from its embedded documents and the host gave no pin
- **THEN** import rebuilds from the verified documents, and the indexed scopes match the documents

#### Scenario: Older index schema

- **WHEN** a pinned cassette was built with a different index schema version
- **THEN** import rebuilds from its embedded documents, and reports rebuild mode
