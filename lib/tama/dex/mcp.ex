defmodule Tama.Dex.MCP do
  @moduledoc """
  The `search` and `execute` MCP tools, as definitions and handlers.

  tama-dex runs no MCP server and doesn't depend on one. A host's server
  advertises two tools built from `search_tool/0` and `execute_tool/0`, and
  calls `handle_search/3` and `handle_execute/4` from them. Each definition
  is a map with `name`, `title`, `description`, `input_schema` and
  `output_schema` (JSON Schema 2020-12 maps with string keys) and
  `annotations` (MCP tool hints).

  ## Callers

  A caller is any map or struct whose `scopes` field holds the caller's
  verified scope list, such as `TamaMCP.Context`. The handlers check every
  operation against those scopes, so a host's own scope on the `search` or
  `execute` tool is only an outer gate, never per-operation authorization.
  `handle_execute/4` passes the whole caller to the executor as
  `call.context`.

  ## Responses

  Handlers return JSON-safe maps with string keys, matching the tool's
  output schema, for the host to send as structured content:

  - `search`: `%{"results" => results, "truncated" => boolean}`.
  - `execute`: `%{"cassette", "operation_id", "source", "result"}`; or, for
    the executor's own valid error,
    `%{"cassette", "operation_id", "source", "operation_error", "dispatched" => true}`.
  - Either tool, on failure: `%{"error" => %{"kind", "dispatched", "message"}}`,
    with `"details"` when the kind has any. See `Tama.Dex.Error` for the
    kinds `execute` returns. Arguments that don't match the tool's input
    schema give `"invalid_arguments"` before any lookup.

  An error with `"dispatched" => true` means the operation may have taken
  effect: reconcile its state rather than retrying.

  ## A TamaMCP host

  `TamaMCP.Tool` takes literal schemas, so a host builds its two tool
  modules with a macro that injects the definitions at compile time:

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
          MyHost.Dex
          |> Tama.Dex.MCP.handle_search(arguments, context)
          |> MyHost.DexTool.respond()
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

  The server registers them as `tool MyHost.Tools.Search, name: "search"` and
  `tool MyHost.Tools.Execute, name: "execute"`.
  """

  alias Tama.Dex.Error
  alias Tama.Dex.Index
  alias Tama.Dex.Issues
  alias Tama.Dex.JSON
  alias Tama.Dex.Search

  @max_query_bytes 512
  @cassette_pattern "^[a-z][a-z0-9_]{0,63}$"
  @operation_id_pattern "^[a-z][a-z0-9_]{0,127}$"

  @type definition :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          input_schema: map(),
          output_schema: map(),
          annotations: %{atom() => boolean()}
        }

  @type caller :: %{required(:scopes) => [String.t()], optional(atom()) => term()}

  # Schemas

  @search_kinds ["invalid_arguments", "not_ready"]
  @execute_kinds [
    "invalid_arguments",
    "not_found",
    "not_ready",
    "no_executor",
    "invalid_input",
    "confirmation_required",
    "dispatch_failed",
    "invalid_output"
  ]

  @search_input %{
    "type" => "object",
    "properties" => %{
      "query" => %{
        "type" => "string",
        "maxLength" => @max_query_bytes,
        "description" =>
          "Words to look for in operation IDs, summaries, tags, descriptions and input fields. " <>
            "Each word matches as a prefix, and all must match. Omit to list operations."
      },
      "cassette" => %{
        "type" => "string",
        "pattern" => @cassette_pattern,
        "description" => "Only operations in this cassette."
      },
      "source" => %{
        "type" => "string",
        "minLength" => 1,
        "description" => "Only operations from this source."
      },
      "tags" => %{
        "type" => "array",
        "items" => %{"type" => "string", "minLength" => 1},
        "uniqueItems" => true,
        "maxItems" => 16,
        "description" => "Only operations carrying every listed tag."
      },
      "limit" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => 20,
        "default" => 5,
        "description" => "The most results to return."
      },
      "include_schemas" => %{
        "type" => "boolean",
        "default" => true,
        "description" => "Include each result's input schema."
      }
    },
    "additionalProperties" => false
  }

  @execute_input %{
    "type" => "object",
    "required" => ["cassette", "operation_id", "input"],
    "properties" => %{
      "cassette" => %{
        "type" => "string",
        "pattern" => @cassette_pattern,
        "description" => "The cassette, copied from a search result."
      },
      "operation_id" => %{
        "type" => "string",
        "pattern" => @operation_id_pattern,
        "description" => "The operation ID, copied from a search result."
      },
      "input" => %{
        "type" => "object",
        "description" =>
          "The operation's input, matching the input_schema of its search result, " <>
            "including any confirmation field."
      }
    },
    "additionalProperties" => false
  }

  @string_list %{"type" => "array", "items" => %{"type" => "string"}}

  @search_result %{
    "type" => "object",
    "required" => [
      "cassette",
      "cassette_version",
      "operation_id",
      "source",
      "summary",
      "description",
      "description_truncated",
      "tags",
      "scopes",
      "destructive",
      "deprecated",
      "confirmation",
      "bounds"
    ],
    "properties" => %{
      "cassette" => %{"type" => "string"},
      "cassette_version" => %{"type" => ["string", "null"]},
      "operation_id" => %{"type" => "string"},
      "source" => %{"type" => "string"},
      "summary" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "description_truncated" => %{"type" => "boolean"},
      "tags" => @string_list,
      "scopes" => @string_list,
      "destructive" => %{"type" => "boolean"},
      "deprecated" => %{"type" => "boolean"},
      "confirmation" => %{
        "oneOf" => [
          %{"type" => "null"},
          %{
            "type" => "object",
            "required" => ["field", "description"],
            "properties" => %{
              "field" => %{"type" => "string"},
              "description" => %{"type" => "string"}
            },
            "additionalProperties" => false
          }
        ]
      },
      "bounds" => %{
        "type" => "object",
        "additionalProperties" => %{"type" => "integer", "minimum" => 0}
      },
      "input_schema" => %{"type" => "object"},
      "schema_omitted" => %{"const" => true}
    },
    "additionalProperties" => false
  }

  @search_output %{
    "type" => "object",
    "oneOf" => [
      %{
        "type" => "object",
        "required" => ["results", "truncated"],
        "properties" => %{
          "results" => %{"type" => "array", "items" => @search_result},
          "truncated" => %{"type" => "boolean"}
        },
        "additionalProperties" => false
      }
    ]
  }

  @operation_fields %{
    "cassette" => %{"type" => "string"},
    "operation_id" => %{"type" => "string"},
    "source" => %{"type" => "string"}
  }

  @execute_output %{
    "type" => "object",
    "oneOf" => [
      %{
        "type" => "object",
        "required" => ["cassette", "operation_id", "source", "result"],
        "properties" => Map.put(@operation_fields, "result", %{"type" => "object"}),
        "additionalProperties" => false
      },
      %{
        "type" => "object",
        "required" => ["cassette", "operation_id", "source", "operation_error", "dispatched"],
        "properties" =>
          Map.merge(@operation_fields, %{
            "operation_error" => %{"type" => "object"},
            "dispatched" => %{"const" => true}
          }),
        "additionalProperties" => false
      }
    ]
  }

  defp error_schema(kinds) do
    %{
      "type" => "object",
      "required" => ["error"],
      "properties" => %{
        "error" => %{
          "type" => "object",
          "required" => ["kind", "dispatched", "message"],
          "properties" => %{
            "kind" => %{"enum" => kinds},
            "dispatched" => %{"type" => "boolean"},
            "message" => %{"type" => "string", "maxLength" => 256},
            "details" => %{"type" => "object"}
          },
          "additionalProperties" => false
        }
      },
      "additionalProperties" => false
    }
  end

  @doc "The `search` tool definition."
  @spec search_tool() :: definition()
  def search_tool do
    %{
      name: "search",
      title: "Search operations",
      description:
        "Find operations you can run with the execute tool. Results list only operations " <>
          "your scopes allow, ranked across every cassette. Each gives the cassette and " <>
          "operation_id to pass to execute, its input_schema, and any confirmation field " <>
          "the input must include. Destructive operations are marked.",
      input_schema: @search_input,
      output_schema: put_error(@search_output, @search_kinds),
      annotations: %{
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }
    }
  end

  @doc "The `execute` tool definition."
  @spec execute_tool() :: definition()
  def execute_tool do
    %{
      name: "execute",
      title: "Execute an operation",
      description:
        "Run one operation found with the search tool. Pass its cassette and operation_id, " <>
          "and an input matching its input_schema, including any confirmation field. " <>
          "The input is checked before the operation runs, and the operation runs at most " <>
          "once. An error with dispatched true means the operation may have taken effect: " <>
          "check its state with another operation instead of retrying.",
      input_schema: @execute_input,
      output_schema: put_error(@execute_output, @execute_kinds),
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }
    }
  end

  # The error object is the last alternative of each output schema.
  defp put_error(schema, kinds), do: Map.update!(schema, "oneOf", &(&1 ++ [error_schema(kinds)]))

  # Handlers

  @doc """
  Handles a `search` tool call: searches the operations the caller's scopes
  allow, using the tool's arguments.

  Returns `%{"results" => results, "truncated" => boolean}`, with the result
  fields of `Tama.Dex.search/3`, or an `"error"` object. Raises
  `ArgumentError` when `caller` has no `scopes` list.
  """
  @spec handle_search(Index.t(), term(), caller()) :: map()
  def handle_search(index, arguments, caller) do
    scopes = scopes!(caller)

    with :ok <- check_arguments(:search_input, @search_input, arguments),
         :ok <- check_query(arguments) do
      opts =
        [
          scopes: scopes,
          cassette: arguments["cassette"],
          source: arguments["source"],
          tags: Map.get(arguments, "tags", []),
          limit: Map.get(arguments, "limit", 5),
          include_schemas: Map.get(arguments, "include_schemas", true)
        ]

      case Tama.Dex.search(index, arguments["query"], opts) do
        {:ok, response} ->
          json_safe(response)

        {:error, :not_ready} ->
          error_object(
            "not_ready",
            false,
            "The operation index is still loading. Try again shortly.",
            %{}
          )
      end
    end
  end

  @doc """
  Handles an `execute` tool call: runs `Tama.Dex.execute/5` with the
  caller's scopes, the host's `executors` (see `Tama.Dex.Executor`) and the
  caller as `call.context`.

  Returns the result, the executor's own valid error with
  `"dispatched" => true`, or an `"error"` object. Raises `ArgumentError`
  when `caller` has no `scopes` list or `executors` isn't a map.
  """
  @spec handle_execute(Index.t(), term(), caller(), map()) :: map()
  def handle_execute(index, arguments, caller, executors) do
    scopes = scopes!(caller)

    with :ok <- check_arguments(:execute_input, @execute_input, arguments) do
      %{"cassette" => cassette, "operation_id" => operation_id, "input" => input} = arguments

      index
      |> Tama.Dex.execute(cassette, operation_id, input,
        scopes: scopes,
        executors: executors,
        context: caller
      )
      |> execute_response()
    end
  end

  defp execute_response({:ok, %{result: result} = outcome}) do
    outcome |> operation_fields() |> Map.put("result", result)
  end

  defp execute_response({:error, %Error{} = error}) do
    error_object(Atom.to_string(error.kind), error.dispatched, error.message, error.details)
  end

  defp execute_response({:error, %{operation_error: operation_error} = outcome}) do
    outcome
    |> operation_fields()
    |> Map.merge(%{"operation_error" => operation_error, "dispatched" => true})
  end

  defp operation_fields(outcome) do
    %{
      "cassette" => outcome.cassette,
      "operation_id" => outcome.operation_id,
      "source" => outcome.source
    }
  end

  # The caller's message never includes the caller, which may hold claims.
  defp scopes!(caller) when is_map(caller) do
    case Map.get(caller, :scopes) do
      scopes when is_list(scopes) -> Search.scopes!(scopes)
      _other -> raise ArgumentError, "the caller must have a :scopes list of verified scopes"
    end
  end

  defp scopes!(_caller) do
    raise ArgumentError, "the caller must be a map or struct with a :scopes list"
  end

  defp check_arguments(key, schema, arguments) do
    with true <- is_map(arguments) and JSON.data?(arguments),
         :ok <- JSONSchex.validate(compiled(key, schema), arguments) do
      :ok
    else
      false ->
        invalid_arguments("The arguments must be a JSON object.", %{})

      {:error, errors} ->
        invalid_arguments(
          "The arguments do not match the tool's input schema.",
          Issues.from_errors(errors)
        )
    end
  end

  # A schema's maxLength counts characters, and the query limit is in bytes.
  defp check_query(%{"query" => query}) when byte_size(query) > @max_query_bytes do
    invalid_arguments("The query is over #{@max_query_bytes} bytes.", %{
      issues: [%{pointer: "/query", message: "must be at most #{@max_query_bytes} bytes"}],
      issues_truncated: false
    })
  end

  defp check_query(_arguments), do: :ok

  defp invalid_arguments(message, details) do
    error_object("invalid_arguments", false, message, details)
  end

  defp error_object(kind, dispatched, message, details) do
    error = %{"kind" => kind, "dispatched" => dispatched, "message" => message}
    error = if details == %{}, do: error, else: Map.put(error, "details", json_safe(details))
    %{"error" => error}
  end

  # Tool schemas are compiled once per node and kept in :persistent_term,
  # keyed by their content so a changed schema is never served stale.
  defp compiled(key, schema) do
    term_key = {__MODULE__, key, :erlang.phash2(schema)}

    case :persistent_term.get(term_key, nil) do
      nil ->
        {:ok, compiled} = JSONSchex.compile(schema, draft: "draft2020_12")
        :persistent_term.put(term_key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  # String keys and string atoms, for structured content.
  defp json_safe(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key
end
