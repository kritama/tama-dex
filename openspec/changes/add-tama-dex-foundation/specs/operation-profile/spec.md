# Spec Delta

## ADDED Requirements

### Requirement: Tama operations profile document

tama-dex SHALL accept operation documents only in the Tama operations profile
of OpenAPI 3.1, version `tama-operations/1`, as defined in
`docs/tama-operations-profile.md`.

A document MUST have:
- an `openapi` version matching `3.1.x`;
- `info.title` and `info.version`;
- `x-tama-profile` equal to `tama-operations/1`;
- an `x-tama-source` ID matching `^[a-z][a-z0-9_]{0,63}$`;
- only operation paths, and no `webhooks`.

The profile document, the published JSON Schema in
`priv/profile/tama-operations-1.schema.json` and `Tama.Dex.Profile.validate/1`
SHALL agree.

#### Scenario: Valid producer document

- **WHEN** a producer passes a document that follows every profile rule
- **THEN** `Tama.Dex.Profile.validate/1` returns `{:ok, document}`, holding the source ID, version, digest and normalized operations

#### Scenario: Unknown profile version

- **WHEN** `x-tama-profile` is missing or is anything other than `tama-operations/1`
- **THEN** validation fails with a stable `unsupported_profile` issue, and no operation is read

### Requirement: Operation entries

Each operation SHALL be the single `post` operation of path
`/operations/{operationId}`, whose suffix equals its `operationId`.

- `operationId` MUST match `^[a-z][a-z0-9_]{0,127}$` and be unique within the
  document.
- `summary` (at most 120 characters) and `description` (at most 4096) MUST be
  present.
- The request body MUST be required and hold exactly one `application/json`
  object schema.
- `responses` MUST hold `200` and MAY hold `default`, each with an
  `application/json` schema, and no other keys.
- `x-tama-scopes` MUST be a non-empty array of unique scope tokens.
- `x-tama-destructive` MUST be a boolean.
- `x-tama-confirmation`, when present, MUST name a required top-level string
  property of the input schema and give a description of at most 256
  characters.
- `x-tama-bounds`, when present, MUST map snake_case keys to non-negative
  integers. They are informational and never enforced.
- `x-tama-identity`, when present, MUST list at most 8 unique top-level
  property names declared by the `200` or `default` schema.
- Unknown `x-tama-*` keys MUST be rejected. Other `x-<prefix>-*` extensions
  SHALL be kept as opaque metadata of at most 16 KiB per operation.

#### Scenario: Path and identifier disagree

- **WHEN** path `/operations/incus_instance_list` holds `operationId` `incus_instance_get`
- **THEN** validation fails with an issue pointing at that operation

#### Scenario: Confirmation names a missing field

- **WHEN** `x-tama-confirmation.field` is not a required string property of the input schema
- **THEN** validation fails with an `invalid_confirmation` issue

#### Scenario: Producer extension preserved

- **WHEN** an operation carries `x-opsmaru-requires`
- **THEN** it is preserved and returned with that operation's full detail, and never used for search ranking or authorization

### Requirement: Schema dialect and references

Operation schemas SHALL be validated as JSON Schema 2020-12. `jsonSchemaDialect`
MAY be absent; otherwise it MUST be the OAS 3.1 base dialect or the 2020-12
meta-schema URI.

A `$ref` MUST resolve within `#/components/schemas/` of the same document.
External references MUST be rejected. Every operation schema MUST compile
before the document is accepted.

#### Scenario: External reference

- **WHEN** a schema references `https://example.com/schema.json` or another file
- **THEN** validation fails, and nothing is fetched

### Requirement: Validation reporting and limits

`Tama.Dex.Profile.validate/1` SHALL be pure: no process, file or network access.
It SHALL report every issue it finds, each with a JSON pointer, a stable code
and a message of at most 256 bytes.

Documents MUST be at most 4 MiB once serialized and hold at most 1024
operations. Each request or response schema MUST be at most 256 KiB.

#### Scenario: Several defects

- **WHEN** a document has a duplicate `operationId`, a missing summary and an oversized schema
- **THEN** all three issues are returned together, with their pointers

#### Scenario: Oversized document

- **WHEN** a document exceeds 4 MiB or 1024 operations
- **THEN** validation fails with a limit issue, without compiling any schema
