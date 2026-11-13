defmodule Tama.Dex.Issues do
  @moduledoc false

  # Bounded issues from JSON Schema validation errors, for invalid execute
  # input and invalid MCP tool arguments.
  #
  # Messages name the failed keyword and its constraint from the schema,
  # never the value being validated. A missing property is reported at its
  # own pointer.

  alias Tama.Dex.JSON
  alias Tama.Dex.Text

  @max_issues 16

  @type issue :: %{pointer: String.t(), message: String.t()}

  @doc "At most 16 issues from jsonschex errors, and whether more were cut."
  @spec from_errors([map()]) :: %{issues: [issue()], issues_truncated: boolean()}
  def from_errors(errors) do
    issues = Enum.flat_map(errors, &issues/1)

    %{
      issues: Enum.take(issues, @max_issues),
      issues_truncated: length(issues) > @max_issues
    }
  end

  defp issues(%{path: path, rule: :required, context: %{contrast: names}})
       when is_list(names) do
    for name <- names, do: issue(reverse(path) ++ [name], "is required")
  end

  defp issues(%{path: path, rule: rule, context: context}) do
    [issue(reverse(path), message(rule, context))]
  end

  # jsonschex lists error paths innermost first.
  defp reverse(path), do: path |> List.wrap() |> Enum.reverse()

  defp issue(path, message) do
    %{
      pointer: path |> JSON.pointer() |> Text.bound(256),
      message: Text.bound(message, 256)
    }
  end

  defp message(:type, %{contrast: type}), do: "must be of type #{format_type(type)}"
  defp message(:boolean_schema, _context), do: "is not allowed"
  defp message(rule, _context), do: "fails the #{rule} keyword"

  defp format_type(types) when is_list(types), do: Enum.join(types, " or ")
  defp format_type(type), do: to_string(type)
end
