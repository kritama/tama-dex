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
