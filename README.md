# TamaDex

Index and search for operation catalogues, so an MCP server can expose just two
tools, `search` and `execute`, in place of one tool per operation.

> Pre-release. The design is in
> `openspec/changes/add-tama-dex-foundation/`; nothing is implemented yet.

## Why

A host such as Macus exposes dozens of operations from several sources. For
example, `opsmaru_incus` alone provides 32 Incus operations, and Macus adds its
own runtime operations. One MCP tool per operation floods `tools/list`, and
each source would otherwise invent its own description format. TamaDex
replaces that with:

1. **One ingestion standard.** Every source publishes an OpenAPI 3.1 document
   in the [Tama operations profile](docs/tama-operations-profile.md)
   (`tama-operations/1`). It uses ordinary OpenAPI plus a few `x-tama-*`
   extensions for scopes, destructive operations and confirmation rules.
2. **A SQLite index.** The host loads profile documents into an index it owns.
   Each source replaces its own entries atomically.
3. **`search`.** Full-text search over operation IDs, summaries, descriptions,
   tags and input fields. It only returns operations the caller's verified
   scopes allow.
4. **`execute`.** It checks the caller's scopes, any confirmation rule and the
   input schema, then hands the call to the executor the host registered for
   that source, for example `Opsmaru.Incus.Operations.run/3`.

## Boundary

```text
 opsmaru_incus ──┐  tama-operations/1 documents (data)
 Macus runtime ──┤
                 v
   host (e.g. Macus) ── TamaDex.Index (SQLite, host-supervised)
                 │
                 └── MCP server: search / execute ── TamaDex handlers
                                                       │
                                     host executor per source (run/3, ...)
```

TamaDex is a library. It starts nothing on load, holds no listener, never
fetches documents over the network, and never runs an operation itself. It
doesn't depend on `tama_mcp`. It provides the two tool definitions as data
for the host's MCP server.

## Development

```console
mise trust && mise install
mise run spec:validate
```

See `AGENTS.md` for the project rules and Git Flow.

## License

Apache-2.0
