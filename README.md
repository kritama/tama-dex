# tama-dex

Index and search for operation catalogues, so an MCP server can expose just two
tools, `search` and `execute`, in place of one tool per operation.

> Pre-release: `0.1.0` is not yet published. The design is in
> `openspec/changes/add-tama-dex-foundation/`.

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
   call to the executor the host registered for that source: a host module
   implementing `Tama.Dex.Executor`, typically an adapter around the
   producer's own run function.

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
                                     host executor per source (Tama.Dex.Executor)
```

tama-dex is a library. It starts nothing on load, holds no listener, never
fetches documents or cassettes over the network, and never runs an operation itself. It
doesn't depend on `tama_mcp`. It provides the two tool definitions as data
for the host's MCP server.

## Installation

```elixir
def deps do
  [
    {:tama_dex, "~> 0.1"}
  ]
end
```

## Usage

### Start an index

The host starts the index under its own supervisor, with an explicit
database path. Loading the dependency starts nothing.

```elixir
children = [
  {Tama.Dex.Index, path: "/var/lib/my_host/tama-dex.sqlite3", name: MyHost.Dex}
]
```

Use `path: :memory` in tests. The database is derived data: one with an
unknown storage schema version is recreated empty, and the host installs its
documents again.

### Install documents and cassettes

Load a profile document into a cassette, a namespace the host names. A load
validates the whole document and replaces that source atomically. An
unchanged document is a no-op.

```elixir
{:ok, _loaded} =
  Tama.Dex.load(MyHost.Dex, MyHost.Runtime.operations_document(), cassette: "macus")
```

Or import a cassette a producer published, from a local file the host
supplies. Pinning the published SHA-256 lets the prebuilt rows be copied.
Without a pin, the index is rebuilt from the documents embedded in the
cassette.

```elixir
{:ok, %{cassette: "opsmaru_incus", mode: :copy}} =
  Tama.Dex.import(MyHost.Dex, "priv/cassettes/opsmaru_incus-1.4.0.tama-cassette",
    sha256: "9f2c…"
  )
```

To keep startup bounded, pass `timeout:` (the work rolls back when it runs
out) or `async: true` (returns `{:ok, ref}`, then sends
`{:tama_dex_import, ref, result}`). `Tama.Dex.Index.status/1` and
`Tama.Dex.cassettes/1` report readiness. While nothing is committed, search
and execute answer `not_ready` instead of waiting.

### Register executors

tama-dex never runs an operation. `execute` validates the call, then hands it
to the executor the host registered for the operation's source:

```elixir
defmodule MyHost.IncusExecutor do
  @behaviour Tama.Dex.Executor

  @impl Tama.Dex.Executor
  def execute(%Tama.Dex.Call{} = call, input) do
    OpsmaruIncus.run(call.operation_id, input,
      authorizer: Keyword.fetch!(call.opts, :authorizer),
      scopes: call.scopes
    )
  end
end

def executors do
  %{"opsmaru_incus" => {MyHost.IncusExecutor, authorizer: MyHost.Authorizer}}
end
```

### Search and execute

Both take the caller's verified scopes. Search only shows operations those
scopes allow, and execute checks them again on every call.

```elixir
{:ok, %{results: [%{cassette: "opsmaru_incus", operation_id: "incus_instance_list"} | _]}} =
  Tama.Dex.search(MyHost.Dex, "list instances", scopes: caller.scopes)

{:ok, %{result: result}} =
  Tama.Dex.execute(MyHost.Dex, "opsmaru_incus", "incus_instance_list", %{},
    scopes: caller.scopes,
    executors: executors(),
    context: caller
  )
```

An error is a `Tama.Dex.Error` with a `kind` and `dispatched`.
`dispatched: true` means the executor was called, so the operation may have
taken effect. tama-dex never retries.

### Build a cassette

A producer's CI builds a cassette from its profile documents and publishes
it with the printed SHA-256:

```console
mix tama.dex.cassette --name acme --version 1.0.0 \
  --document Acme.Operations.openapi \
  --output acme-1.0.0.tama-cassette
```

### Telemetry

tama-dex emits `[:tama_dex, :load | :import | :search | :execute, ...]` spans
and `[:tama_dex, :index, :recreated | :status]` events. Their metadata never
holds query text, inputs, results, schemas or file paths. See
`Tama.Dex.Telemetry`.

## MCP tools

`Tama.Dex.MCP.search_tool/0` and `execute_tool/0` return the two tool
definitions as data: a name, title, description, JSON Schema 2020-12 input
and output schemas, and annotations. `handle_search/3` and `handle_execute/4`
take the index, the tool arguments and the caller, and return JSON-safe maps
matching those output schemas. A caller is any map or struct with a `scopes`
list, such as `TamaMCP.Context`; every operation is checked against those
scopes, so the host's scope on each tool is only an outer gate.

`TamaMCP.Tool` accepts only literal schemas, so a TamaMCP host injects the
definitions with a small macro:

```elixir
defmodule MyHost.DexTool do
  defmacro __using__(opts) do
    tool = apply(Tama.Dex.MCP, Keyword.fetch!(opts, :tool), [])

    quote do
      use TamaMCP.Tool,
        scopes: unquote(Keyword.fetch!(opts, :scopes)),
        title: unquote(tool.title),
        description: unquote(tool.description),
        annotations: unquote(Map.to_list(tool.annotations))

      raw_input_schema(unquote(Macro.escape(tool.input_schema)))
      raw_output_schema(unquote(Macro.escape(tool.output_schema)))
    end
  end

  def respond(structured) do
    failed? = Map.has_key?(structured, "error") or Map.has_key?(structured, "operation_error")
    build = if failed?, do: &TamaMCP.Response.tool_error/1, else: &TamaMCP.Response.success/1

    {:ok,
     build.(
       structured_content: structured,
       content: [TamaMCP.Response.text(Jason.encode!(structured))]
     )}
  end
end

defmodule MyHost.Tools.Search do
  use MyHost.DexTool, tool: :search_tool, scopes: ["ops.search"]

  @impl TamaMCP.Tool
  def call(arguments, context) do
    MyHost.Dex |> Tama.Dex.MCP.handle_search(arguments, context) |> MyHost.DexTool.respond()
  end
end

defmodule MyHost.Tools.Execute do
  use MyHost.DexTool, tool: :execute_tool, scopes: ["ops.execute"]

  @impl TamaMCP.Tool
  def call(arguments, context) do
    MyHost.Dex
    |> Tama.Dex.MCP.handle_execute(arguments, context, MyHost.executors())
    |> MyHost.DexTool.respond()
  end
end

defmodule MyHost.MCP do
  use TamaMCP.Server, name: "my_host", version: "1.0.0"

  tool MyHost.Tools.Search, name: "search"
  tool MyHost.Tools.Execute, name: "execute"
end
```

`MyHost.executors/0` returns the host's executor registrations, such as
`%{"opsmaru_incus" => {MyHost.IncusExecutor, authorizer: MyHost.Authorizer}}`
(see `Tama.Dex.Executor`). An `execute` error with `"dispatched" => true`
means the operation may have taken effect, so the agent should reconcile
rather than retry.

## Development

```console
mise trust && mise install
mise run spec:validate
```

See `AGENTS.md` for the project rules and Git Flow.

## License

Apache-2.0
