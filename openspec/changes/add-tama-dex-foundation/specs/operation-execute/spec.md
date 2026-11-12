# Spec Delta

## ADDED Requirements

### Requirement: Validation before dispatch

`Tama.Dex.execute/5` SHALL take a required cassette name and an
`operationId`, and run in the caller's process. It SHALL check, in order:

1. the operation exists in that cassette and is visible to the caller's
   verified scopes, reporting `not_found` otherwise, including for unknown
   cassettes and for operations that exist but are hidden, and `not_ready`
   for a cassette whose first import is still running;
2. an executor is registered for the operation's source (`no_executor`
   otherwise);
3. the input is a map of at most 1 MiB once encoded that validates against
   the compiled input schema (`invalid_input`, with bounded JSON-pointer
   issues, otherwise);
4. the confirmation field, when the operation declares one, is present and
   non-empty (`confirmation_required`, with the field and description,
   otherwise).

No executor SHALL be called unless every check passes.

#### Scenario: Operation looked up in the named cassette only

- **WHEN** `list_instances` exists in the `macus` cassette but not in `opsmaru_incus`, and a caller executes it with `cassette: "opsmaru_incus"`
- **THEN** execute returns `not_found`, and the `macus` operation is not run

#### Scenario: Missing scope

- **WHEN** a caller holding `incus.read` executes `incus_image_delete`
- **THEN** execute returns `not_found`, and no executor is called

#### Scenario: Invalid input

- **WHEN** the input omits a required property
- **THEN** execute returns `invalid_input`, with that property's pointer, and no executor is called

#### Scenario: Missing confirmation

- **WHEN** `incus_image_delete` is executed without `confirm`
- **THEN** execute returns `confirmation_required`, with field `confirm` and description `the full fingerprint`

### Requirement: Single dispatch to host executors

After validation, execute SHALL call the source's executor exactly once, as
`executor.(operation_id, input, context)`. An executor is a 3-arity function
or `{module, function, extra_args}`, returning `{:ok, map}` or
`{:error, map}`.

- tama-dex MUST NOT impose a deadline of its own around the executor.
  Operation duration is limited only by the executor and host.
- Raises, exits and throws SHALL be caught and reported as `dispatch_failed`,
  with only their kind.
- tama-dex MUST NOT retry, replay or queue a dispatched call, because the
  operation may already have been accepted.
- tama-dex MUST NOT perform the operation itself or add authorization beyond
  the scope check. Confirmation values, policy and timeouts belong to the
  executor.

#### Scenario: Long-running executor

- **WHEN** an executor for a runtime start takes 900 seconds within its own caller-supplied budget
- **THEN** execute waits for it and returns its result, without a tama-dex timeout

#### Scenario: Executor raises

- **WHEN** the executor raises after a backend may have accepted the operation
- **THEN** execute returns `dispatch_failed` once, and the executor is not called again

#### Scenario: Executor rejects

- **WHEN** the executor returns `{:error, error}` matching the declared `default` schema
- **THEN** execute returns that error unchanged

### Requirement: Result validation

- A `{:ok, result}` SHALL match the operation's `200` schema.
- An `{:error, error}` SHALL match its `default` schema when one is declared.
- A mismatch SHALL return `invalid_output`, without any of the result's
  content except the values of the operation's `x-tama-identity` properties
  that are top-level strings, integers or booleans of at most 256 bytes.
- A valid success SHALL return `{:ok, %{cassette, operation_id, source, result}}`.

#### Scenario: Producer bug

- **WHEN** an executor returns a success map that violates the `200` schema
- **THEN** execute returns `invalid_output` with `dispatched: true` and the declared identity values (for example `operation_id`), and the rest of the map is neither returned nor logged

### Requirement: Dispatch status in errors

Every error tama-dex produces SHALL carry `dispatched`.

- `not_found`, `not_ready`, `no_executor`, `invalid_input` and
  `confirmation_required` SHALL carry `dispatched: false`.
- `dispatch_failed` and `invalid_output` SHALL carry `dispatched: true`, with
  a message stating that the operation may have taken effect and must be
  reconciled rather than retried.
- An executor's own valid `{:error, error}` SHALL be passed through unchanged.

#### Scenario: Caller distinguishes run from not run

- **WHEN** one call fails `invalid_input` and another fails `invalid_output`
- **THEN** the first carries `dispatched: false`, and the second `dispatched: true` with the reconcile message

### Requirement: No retention of inputs or results

tama-dex MUST NOT store, index, log or emit in telemetry any `execute` input,
result or error content. Errors produced by tama-dex SHALL carry a stable kind
and a message of at most 256 bytes.

#### Scenario: Telemetry for an execute

- **WHEN** an execute completes
- **THEN** its telemetry metadata contains only the cassette, source, operation ID, outcome kind and duration
