# Spec Delta

## ADDED Requirements

### Requirement: Tool definitions as data

`Tama.Dex.MCP.search_tool/0` and `execute_tool/0` SHALL return the `search` and
`execute` tool definitions as JSON-safe data, each with a name, title,
description, JSON Schema 2020-12 input and output schemas, and annotations.

- `search` input SHALL accept `query`, `cassette`, `source`, `tags`, `limit`
  and `include_schemas`. Each search result SHALL name its cassette.
- `execute` input SHALL require `cassette`, `operation_id` and `input`.
- Both schemas MUST reject unknown properties.
- The `search` schema SHALL bound `limit` to 1–20. The handler SHALL also
  check the 512-byte query limit, because a schema's `maxLength` counts
  characters, and return `invalid_arguments` for longer text.
- tama-dex MUST NOT depend on `tama_mcp` or start an MCP server.

#### Scenario: Host builds TamaMCP tools

- **WHEN** a host declares TamaMCP tool modules with `raw_input_schema` and `raw_output_schema` taken from these definitions
- **THEN** the host advertises exactly the two tools, with schemas identical to tama-dex's

### Requirement: Tool handlers

- `Tama.Dex.MCP.handle_search/3` SHALL take the index, tool arguments and a
  caller, and return the search response as a JSON-safe map. A caller is any
  map or struct whose `scopes` field holds the verified scope list, such as
  `TamaMCP.Context`. A caller without one SHALL raise an argument error.
- `Tama.Dex.MCP.handle_execute/4` SHALL also take the host's executor
  registrations, pass the caller as the call's `context`, and return the
  execute result, the executor's operation error (with `dispatched: true`), or
  an `error` object with a stable kind and the `dispatched` flag.
- Handlers SHALL use the caller's verified scopes for every operation. A
  host's MCP tool scope is only an outer gate, never per-operation
  authorization.

#### Scenario: Tool scope without operation scope

- **WHEN** a caller allowed to call the `execute` tool, but without `incus.delete`, executes `incus_instance_delete` in the `opsmaru_incus` cassette
- **THEN** the handler returns a `not_found` error object, and no executor is called

#### Scenario: TamaMCP context as caller

- **WHEN** a host passes its `TamaMCP.Context`, whose `scopes` are `["incus.read"]`, as the caller
- **THEN** the handlers filter by `incus.read`, and `handle_execute/4` passes that same context as `call.context`

#### Scenario: Index not ready

- **WHEN** a caller uses either tool while the host's first import is still running
- **THEN** the handler returns a `not_ready` error object with `dispatched: false`, and does not wait

#### Scenario: Arguments fail the tool schema

- **WHEN** `handle_execute/4` receives arguments without `cassette` or without `operation_id`
- **THEN** it returns an `invalid_arguments` error object, without looking up any operation
