# Spec Delta

## ADDED Requirements

### Requirement: Executor behaviour

tama-dex SHALL define the `Tama.Dex.Executor` behaviour as the only way
`execute` hands a validated call to a host.

- It SHALL have one callback, `execute(call, input)`, returning `{:ok, map}`
  or `{:error, map}`.
- `call` SHALL be a `%Tama.Dex.Call{}` with `cassette`, `source`,
  `operation_id`, `scopes`, `context` and `opts`.
- `scopes` SHALL be the same verified scopes tama-dex checked for the call,
  so the executor re-checks against exactly what tama-dex saw.
- `context` SHALL be the host term passed to `execute` (for the MCP handler,
  the caller), and `opts` the options given at registration.
- Input SHALL be passed already validated against the operation's input
  schema, and MUST NOT be altered by tama-dex.

#### Scenario: Executor receives the checked scopes

- **WHEN** a caller holding `incus.read` and `incus.delete` executes `incus_instance_delete` in the `opsmaru_incus` cassette
- **THEN** the executor's `call.scopes` is exactly `["incus.delete", "incus.read"]` as verified, with cassette `opsmaru_incus`, source `opsmaru_incus` and operation ID `incus_instance_delete`

### Requirement: Executor registration

Hosts SHALL register executors per source, as a map from source ID to a
module implementing `Tama.Dex.Executor`, or `{module, opts}`.

- A source with no entry SHALL fail with `no_executor` before dispatch.
- An entry that is not a loaded module exporting `execute/2` SHALL fail with
  `no_executor` before dispatch, naming the source but not the module.
- The same registration SHALL serve every cassette carrying that source.

#### Scenario: Registration with options

- **WHEN** a host registers `%{"opsmaru_incus" => {Macus.Dex.IncusExecutor, host: Macus.MCP.IncusHost}}`
- **THEN** each dispatched call reaches `Macus.Dex.IncusExecutor.execute/2` with `call.opts` equal to `[host: Macus.MCP.IncusHost]`

#### Scenario: Module without the callback

- **WHEN** a source is registered to a module that does not export `execute/2`
- **THEN** execute returns `no_executor` with `dispatched: false`, and nothing is called

### Requirement: Hosts implement executors, producers stay independent

The behaviour SHALL be implemented by host adapter modules, not required of
producers.

- A producer library MUST NOT need tama_dex at runtime or compile time to be
  executable through tama-dex. It provides a profile document as data and its
  own run function.
- A host adapter SHALL translate a `Tama.Dex.Call` into the producer's call,
  supplying host-only arguments such as authorization modules and the
  verified caller.
- tama-dex SHALL NOT define an Elixir protocol for this, because executors
  are chosen by source ID, not by the type of a value.

#### Scenario: opsmaru_incus behind a host adapter

- **WHEN** Macus registers `Macus.Dex.IncusExecutor`, which calls `Opsmaru.Incus.Operations.Composite.run/3` with `host:`, the verified caller from `call.context` and `call.scopes`
- **THEN** opsmaru_incus operations execute through tama-dex, while opsmaru_incus compiles without tama_dex
