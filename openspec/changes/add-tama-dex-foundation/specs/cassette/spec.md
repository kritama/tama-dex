# Spec Delta

## ADDED Requirements

### Requirement: Cassette build

`Tama.Dex.Cassette.build/3` and `mix tama.dex.cassette` SHALL build a
`tama-cassette/1` file holding one cassette, with a required name and version,
from one or more profile documents given as zero-arity functions or JSON
files.

- Every document SHALL be validated, and sources or IDs duplicated within the
  cassette SHALL be rejected before writing.
- The file SHALL hold the version 1 index tables, a manifest (format, cassette
  name and version, tama-dex version, index schema version, SQLite version,
  profile, content digest) and each source's canonical document with its
  digest.
- It MUST NOT store wall-clock time.
- It SHALL be written to a temporary file and renamed into place.
- The task SHALL print the content digest and the file's SHA-256.

#### Scenario: Producer CI build

- **WHEN** a producer's CI runs `mix tama.dex.cassette --name opsmaru_incus --version 0.2.0 --document Opsmaru.Incus.Operations.openapi --document Opsmaru.Incus.NativeOperations.openapi --output opsmaru_incus-0.2.0.tama-cassette`
- **THEN** one `opsmaru_incus` cassette holding both sources is written, and its content digest and SHA-256 are printed

#### Scenario: Reproducible content

- **WHEN** the same documents are built twice with the same tama-dex version
- **THEN** both cassettes have the same content digest

### Requirement: Cassette verification

`Tama.Dex.Cassette.verify/2` SHALL treat a cassette as untrusted input. It
SHALL:
- reject files over 64 MiB before opening;
- check the file's SHA-256 when the host gives one;
- open the file read-only with extension loading disabled;
- require `sqlite_master` to contain exactly the expected tables, indexes and
  FTS shadow tables, with no triggers or views;
- check the manifest format and cassette name;
- recompute every embedded document's digest and the content digest;
- validate every embedded document against the profile.

#### Scenario: Altered document

- **WHEN** an embedded document no longer matches its recorded digest
- **THEN** verification fails, and nothing is imported

#### Scenario: Trigger in cassette

- **WHEN** a cassette contains a trigger or view
- **THEN** verification fails before any row is read

### Requirement: Cassette import

`Tama.Dex.import/3` SHALL verify a cassette, then replace the whole cassette
of that name in one transaction, under the manifest name or the host's `as:`
name.

- It SHALL copy prebuilt rows only when the host supplied a matching SHA-256
  pin and the cassette's index schema version equals the index's.
- In every other case it SHALL rebuild from the embedded documents.
- Sources and operations absent from the new cassette SHALL be removed. Other
  cassettes MUST NOT change.
- Importing the same content digest again SHALL report `changed: false` and
  write nothing.
- It SHALL report the cassette, version, mode, `changed` and sources.
- A host MAY import several cassettes into one index.
- It SHALL honour the `timeout` and `async` options of the startup-bounded
  indexing requirement.
- tama-dex MUST NOT download cassettes. Hosts supply local files.

#### Scenario: Pinned release cassette

- **WHEN** Macus imports `opsmaru_incus-0.2.0.tama-cassette` with the SHA-256 published for that release
- **THEN** both sources are installed in copy mode and are searchable immediately

#### Scenario: Several cassettes in one index

- **WHEN** Macus imports the `opsmaru_incus` cassette and then a second cassette named `macus`
- **THEN** both are installed side by side, searchable together, and the first import is unaffected by the second

#### Scenario: Upgrade drops an operation

- **WHEN** a host imports `opsmaru_incus` 0.3.0 over 0.2.0, and 0.3.0 no longer has one operation
- **THEN** that operation is gone, the rest are replaced atomically, and other cassettes are unchanged

#### Scenario: Name collision between producers

- **WHEN** a host imports a third-party cassette whose manifest name is also `macus`, passing `as: "acme"`
- **THEN** it is installed as `acme`, and the existing `macus` cassette is unchanged

#### Scenario: Unpinned cassette with tampered rows

- **WHEN** a cassette's operation rows grant different scopes from its embedded documents and the host gave no pin
- **THEN** import rebuilds from the verified documents, and the indexed scopes match the documents

#### Scenario: Older index schema

- **WHEN** a pinned cassette was built with a different index schema version
- **THEN** import rebuilds from its embedded documents, and reports rebuild mode
