# Spec Delta

## ADDED Requirements

### Requirement: Scope-filtered search

`Tama.Dex.search/3` SHALL require the caller's verified scopes.

- It SHALL return only operations whose every `x-tama-scopes` entry is among
  those scopes.
- Hidden operations MUST NOT affect result counts, truncation flags or error
  messages.
- Deprecated operations SHALL be excluded unless requested.

#### Scenario: Caller without delete scope

- **WHEN** a caller holding only `incus.read` searches for `delete`
- **THEN** no `incus.delete` operation is returned, and the response does not reveal that any exists

#### Scenario: Scopes not supplied

- **WHEN** `search/3` is called without `scopes`
- **THEN** it fails with an argument error, rather than defaulting to all operations

### Requirement: Safe full-text queries

Search SHALL use SQLite FTS5 over each operation's ID, summary, tags,
description and input property names and descriptions.

- Caller text of at most 512 bytes SHALL be reduced to letter-and-digit terms,
  each quoted, given a prefix wildcard and joined with AND.
- Caller text MUST NOT reach SQLite as FTS5 query syntax.
- Ranking SHALL weight operation ID highest, then summary, tags, description
  and fields. An exact `operationId` match SHALL rank first.
- An empty query SHALL list visible operations in `operationId` order.

#### Scenario: Query syntax in caller text

- **WHEN** a caller searches for `instance" OR NEAR(* -delete`
- **THEN** the search succeeds, treating the text only as the terms `instance`, `or`, `near` and `delete`

#### Scenario: Field name match

- **WHEN** a caller searches for `fingerprint`
- **THEN** operations whose input schema has a `fingerprint` property are returned

### Requirement: Bounded results

- `limit` SHALL default to 5 and MUST NOT exceed 20.
- Each result SHALL include the operation ID, source, summary, description
  (truncated to 1024 characters with a flag), tags, scopes, the destructive and
  deprecated flags, any confirmation rule and bounds, and the input schema
  when requested (default on).
- The encoded response MUST stay within 64 KiB. Input schemas are dropped from
  the lowest-ranked results first, each marked `schema_omitted`, and the
  response sets `truncated` if results themselves were cut.
- `Tama.Dex.describe/3` SHALL return one visible operation in full, including
  response schemas and opaque extensions.

#### Scenario: Large schemas

- **WHEN** the top five results' input schemas together exceed the budget
- **THEN** schemas are removed from the lowest-ranked results first, and each affected result is marked `schema_omitted: true`

#### Scenario: Describe a hidden operation

- **WHEN** `describe/3` is called for an operation the caller's scopes do not allow
- **THEN** it returns `{:error, :not_found}`
