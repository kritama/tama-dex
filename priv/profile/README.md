# Profile schemas

This directory holds the published JSON Schema (2020-12) for each version of
the Tama operations profile, named after the version:
`tama-operations-1.schema.json` for `tama-operations/1`.

Each schema checks a profile document's shape. The rules JSON Schema can't
express, such as a path suffix matching its `operationId`, are applied by
`Tama.Dex.Profile.validate/1`. The profile itself is defined in
`docs/tama-operations-profile.md`, and the schema, that document and the
validator are kept in agreement.
