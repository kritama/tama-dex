defmodule Tama.Dex.TestSupport.HostTool do
  @moduledoc false

  # Stands in for TamaMCP.Tool, which tama-dex must not depend on. Like it,
  # it accepts tool options and raw schemas only as compile-time literals and
  # builds a `definition/0` in the MCP wire shape.

  defmacro __using__(opts) do
    opts = literal!(opts, "tool options", __CALLER__)

    quote do
      import Tama.Dex.TestSupport.HostTool, only: [raw_input_schema: 1, raw_output_schema: 1]
      @host_tool_options unquote(Macro.escape(opts))
      @before_compile Tama.Dex.TestSupport.HostTool
    end
  end

  defmacro raw_input_schema(schema) do
    schema = literal!(schema, "raw_input_schema", __CALLER__)
    quote do: @host_input_schema(unquote(Macro.escape(schema)))
  end

  defmacro raw_output_schema(schema) do
    schema = literal!(schema, "raw_output_schema", __CALLER__)
    quote do: @host_output_schema(unquote(Macro.escape(schema)))
  end

  defmacro __before_compile__(_env) do
    quote do
      def scopes, do: Keyword.fetch!(@host_tool_options, :scopes)

      def definition do
        %{
          "title" => Keyword.fetch!(@host_tool_options, :title),
          "description" => Keyword.fetch!(@host_tool_options, :description),
          "annotations" => Map.new(Keyword.fetch!(@host_tool_options, :annotations)),
          "inputSchema" => @host_input_schema,
          "outputSchema" => @host_output_schema
        }
      end
    end
  end

  defp literal!(expr, label, caller) do
    unless Macro.quoted_literal?(expr) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "#{label} must be a literal, got: #{Macro.to_string(expr)}"
    end

    {value, _binding} = Code.eval_quoted(expr, [], caller)
    value
  end
end

defmodule Tama.Dex.TestSupport.DexTool do
  @moduledoc false

  # The host macro from Tama.Dex.MCP's documentation, over HostTool.

  defmacro __using__(opts) do
    tool = apply(Tama.Dex.MCP, Keyword.fetch!(opts, :tool), [])

    quote do
      use Tama.Dex.TestSupport.HostTool,
        scopes: unquote(Keyword.fetch!(opts, :scopes)),
        title: unquote(tool.title),
        description: unquote(tool.description),
        annotations: unquote(Map.to_list(tool.annotations))

      raw_input_schema(unquote(Macro.escape(tool.input_schema)))
      raw_output_schema(unquote(Macro.escape(tool.output_schema)))
    end
  end
end

defmodule Tama.Dex.TestSupport.HostSearch do
  @moduledoc false
  use Tama.Dex.TestSupport.DexTool, tool: :search_tool, scopes: ["ops.search"]

  alias Tama.Dex.MCP

  def call(index, arguments, context), do: MCP.handle_search(index, arguments, context)
end

defmodule Tama.Dex.TestSupport.HostExecute do
  @moduledoc false
  use Tama.Dex.TestSupport.DexTool, tool: :execute_tool, scopes: ["ops.execute"]

  alias Tama.Dex.MCP

  def call(index, arguments, context, executors),
    do: MCP.handle_execute(index, arguments, context, executors)
end

defmodule Tama.Dex.TestSupport.HostServer do
  @moduledoc false

  # A host server's tools/list, built from its two tool modules.

  @tools [
    {"execute", Tama.Dex.TestSupport.HostExecute},
    {"search", Tama.Dex.TestSupport.HostSearch}
  ]

  def tools_list do
    for {name, module} <- @tools, do: Map.put(module.definition(), "name", name)
  end
end

defmodule Tama.Dex.TestSupport.Context do
  @moduledoc false

  # Shaped like TamaMCP.Context: a struct with verified scopes and claims.
  defstruct [:request_id, :principal, :claims, scopes: []]
end
