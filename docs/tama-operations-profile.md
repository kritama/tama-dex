# Tama operations profile (`tama-operations/1`)

This profile is the standard way for a library or service to publish its
operations so tama-dex can index, search and execute them. A profile document
is an ordinary OpenAPI 3.1 document with a few constraints and `x-tama-*`
extensions. Producers build it as plain data. They don't depend on tama-dex at
runtime, but they may use `Tama.Dex.Profile.validate/1` as a test-only
dependency to check conformance.

Known producers are `opsmaru_incus` (from 0.2.0) and Macus (its runtime
operations). tama-dex never depends on a producer; producers publish documents
as data.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Document

| Field | Rule |
|---|---|
| `openapi` | MUST match `3.1.x`. |
| `jsonSchemaDialect` | MAY be absent, or MUST be `https://spec.openapis.org/oas/3.1/dialect/base` or `https://json-schema.org/draft/2020-12/schema`. Schemas are validated as JSON Schema 2020-12. |
| `info.title`, `info.version` | MUST be present. `info.version` is the producer's release version, for example `0.2.0`. |
| `x-tama-profile` | MUST be exactly `tama-operations/1`. |
| `x-tama-source` | MUST match `^[a-z][a-z0-9_]{0,63}$`. This is the stable source ID that executors are registered under, for example `opsmaru_incus` or `macus`. |
| `paths` | MUST contain only operation paths (see below). |
| `components.schemas` | MAY hold shared schemas. A `$ref` MUST point into `#/components/schemas/` of the same document. External references are rejected. |
| `webhooks` | MUST be absent. |

Other OpenAPI fields, such as `servers`, `tags`, `security` and
`externalDocs`, are allowed and ignored.

The whole serialized document MUST be at most 4 MiB and hold at most 1024
operations.

## Operations

Each operation is one path item, `/operations/{operationId}` with the literal
operation ID, holding exactly one `post` operation. The path and method are
naming conventions only. tama-dex never makes HTTP calls to them.

| Field | Rule |
|---|---|
| `operationId` | MUST match `^[a-z][a-z0-9_]{0,127}$` and equal the path suffix. It MUST be unique within the document, and within the cassette the document is installed in. The same ID MAY appear in other cassettes; hosts address operations by cassette and `operationId`. |
| `summary` | MUST be present, at most 120 characters. |
| `description` | MUST be present, at most 4096 characters. |
| `tags` | MAY list up to 16 unique strings of at most 64 characters, for example the resource name. |
| `deprecated` | MAY be `true`. Deprecated operations stay indexed and are marked in results. |
| `requestBody` | MUST be `required: true`, with exactly one `application/json` media type whose `schema` is an object schema (`"type": "object"`). |
| `responses` | MUST contain `"200"` with an `application/json` schema for a successful result. It MAY contain `"default"` with an `application/json` schema for an error result. No other response keys are allowed. |
| `x-tama-scopes` | MUST be a non-empty array of unique scope tokens matching `^[A-Za-z0-9._:-]{1,128}$`. A caller needs **every** listed scope. |
| `x-tama-destructive` | MUST be a boolean. |
| `x-tama-confirmation` | MAY be `{"field": <name>, "description": <text>}`. `field` MUST name a required top-level string property of the input schema. `description` (at most 256 characters) tells the caller what value to send, for example "the full fingerprint". |
| `x-tama-bounds` | MAY be an object of non-negative integers keyed by `^[a-z][a-z0-9_]{0,63}$`, for example `max_items`. It is informational: returned in results, never enforced by Tama.Dex. |
| `x-tama-identity` | MAY list up to 8 unique top-level property names declared by the `"200"` or `"default"` schema, for example `operation_id` or `status`. When a dispatched result fails validation, tama-dex copies those properties' string, integer or boolean values (each at most 256 bytes) into its `invalid_output` error, so callers can reconcile a call that may already have taken effect. |
| Other `x-<prefix>-*` | Kept as opaque metadata (at most 16 KiB per operation) and returned with full operation detail, for example `x-opsmaru-requires`. |

Where these rules refer to a schema's top-level `type`, `properties` or
`required`, or to a property's type, they mean that schema's own keywords. A
schema that is only a `$ref` into `#/components/schemas/`, optionally with
annotations such as `title` or `description`, is read through to its target.
Keywords inside `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else` or
`$defs` are never consulted. So an input schema that declares its properties
only inside `allOf` has no top-level properties, and can't name a
confirmation field.

Each request or response schema MUST be at most 256 KiB once serialized.

## Execution semantics

- tama-dex validates `requestBody` input before dispatch, and the executor's
  result after it. An `{:ok, result}` MUST match the `"200"` schema. An
  `{:error, error}` MUST match `"default"` when one is declared.
- tama-dex adds no deadline of its own around the executor. Long-running
  operations (for example a runtime start bounded by `remaining_seconds`) are
  limited only by the executor and host. `x-tama-bounds` documents those
  limits but is not enforced.
- Every tama-dex error says whether the executor was called. Errors before
  dispatch carry `dispatched: false`, meaning the operation did not run.
  `dispatch_failed` and `invalid_output` carry `dispatched: true`, meaning the
  operation may have taken effect and MUST NOT be retried blindly.
- When `x-tama-confirmation` is present, tama-dex rejects a call whose
  confirmation field is missing or empty. The producer's executor still checks
  the value itself.
- Scopes are checked against the caller's verified scopes on every `execute`.
  Search hides operations the caller cannot run.

## Example

```json
{
  "openapi": "3.1.1",
  "info": {"title": "opsmaru_incus operations", "version": "0.2.0"},
  "x-tama-profile": "tama-operations/1",
  "x-tama-source": "opsmaru_incus",
  "paths": {
    "/operations/incus_image_delete": {
      "post": {
        "operationId": "incus_image_delete",
        "summary": "Delete an image",
        "description": "Delete an image by fingerprint and wait for the operation.",
        "tags": ["image"],
        "x-tama-scopes": ["incus.delete"],
        "x-tama-destructive": true,
        "x-tama-confirmation": {"field": "confirm", "description": "the full fingerprint"},
        "x-tama-bounds": {"max_wait_seconds": 60, "max_output_bytes": 262144},
        "x-tama-identity": ["operation_id", "status"],
        "x-opsmaru-requires": ["DeleteImage", "GetOperationWait"],
        "requestBody": {
          "required": true,
          "content": {"application/json": {"schema": {"type": "object", "properties": {"fingerprint": {"type": "string"}, "confirm": {"type": "string"}}, "required": ["fingerprint", "confirm"], "additionalProperties": false}}}
        },
        "responses": {
          "200": {"description": "Result", "content": {"application/json": {"schema": {"type": "object"}}}},
          "default": {"description": "Error", "content": {"application/json": {"schema": {"type": "object", "required": ["error"]}}}}
        }
      }
    }
  }
}
```

## Versioning

Unknown `x-tama-*` keys, at document or operation level, are rejected. A new
`x-tama-*` field, a change that would reject a previously valid document, or a
change in the meaning of a field each need a new profile version
(`tama-operations/2`). tama-dex rejects profile versions it doesn't know.
