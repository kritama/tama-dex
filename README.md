# tama-dex

Index and search for operation catalogues, so an MCP server can expose just two
tools, `search` and `execute`, in place of one tool per operation.

> Pre-release. The design is in
> `openspec/changes/add-tama-dex-foundation/`; nothing is implemented yet.

## Why

A host such as Macus exposes dozens of operations from several sources. For
example, `opsmaru_incus` alone provides 32 Incus operations, and Macus adds its
own runtime operations. One MCP tool per operation floods `tools/list`, and
each source would otherwise invent its own description format. tama-dex
replaces that with:

1. **One ingestion standard.** Every source publishes an OpenAPI 3.1 document
   in the [Tama operations profile](docs/tama-operations-profile.md)
   (`tama-operations/1`). It uses ordinary OpenAPI plus a few `x-tama-*`
   extensions for scopes, destructive operations and confirmation rules.
2. **A SQLite index.** The host installs cassettes and profile documents into
   one index it owns. Each cassette is a namespace, such as `opsmaru_incus` or
   `macus`, and is replaced atomically on its own.
3. **`search`.** Full-text search over operation IDs, summaries, descriptions,
   tags and input fields, ranked across every cassette. It only returns
   operations the caller's verified scopes allow, and each result names its
   cassette.
4. **`execute`.** The caller names the cassette and operation. It checks the
   caller's scopes, any confirmation rule and the input schema, then hands the
   call to the executor the host registered for that source, for example
   `Opsmaru.Incus.Operations.run/3`.

5. **Cassettes.** A producer's CI can build a portable, prebuilt index file
   (`.tama-cassette`) with `mix tama.dex.cassette`. For example, every
   opsmaru_incus release publishes an `opsmaru_incus` cassette. A host
   verifies each cassette and imports it at install or start, and can install
   several side by side. Prebuilt rows are copied only when the host pins the
   cassette's SHA-256. Otherwise the index is rebuilt from the documents
   embedded in the cassette.

## Boundary

```text
 opsmaru_incus ──┐  tama-operations/1 documents (data)
 Macus runtime ──┤
                 v
   host (e.g. Macus) ── Tama.Dex.Index (SQLite, host-supervised)
                 │
                 └── MCP server: search / execute ── Tama.Dex handlers
                                                       │
                                     host executor per source (run/3, ...)
```

tama-dex is a library. It starts nothing on load, holds no listener, never
fetches documents or cassettes over the network, and never runs an operation itself. It
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
