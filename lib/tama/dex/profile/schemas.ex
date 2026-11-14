defmodule Tama.Dex.Profile.Schemas do
  @moduledoc false

  # Reads, checks and bundles the JSON Schemas inside a profile document.
  #
  # - Read-through: a schema's top-level keywords are its own, after following
  #   a schema that is only a `$ref` (plus annotations) into
  #   `#/components/schemas/`. Compositions and `$defs` are never consulted.
  # - References: `$ref` and `$dynamicRef` must be JSON Pointers into
  #   `#/components/schemas/` that resolve, and no schema may declare `$id`.
  # - Bundling: the components a schema reaches are carried under `$defs`, so
  #   the bundled schema compiles and validates on its own.

  alias Tama.Dex.JSON
  alias Tama.Dex.Profile.Issue

  @prefix "#/components/schemas/"
  @root_def "tama:root"
  @ref_keywords ["$ref", "$dynamicRef"]
  @annotations ~w($ref title description $comment examples default deprecated readOnly writeOnly)
  @map_keywords ~w($defs definitions properties patternProperties dependentSchemas)
  @single_keywords ~w(items additionalItems additionalProperties unevaluatedProperties unevaluatedItems
                      contains propertyNames not if then else contentSchema)
  @list_keywords ~w(allOf anyOf oneOf prefixItems items)
  @max_depth 32

  @doc "Follows a schema that is only a `$ref` (plus annotations) to its target."
  @spec read_through(term(), map()) :: map() | nil
  def read_through(schema, document), do: read_through(schema, document, 0)

  defp read_through(%{"$ref" => @prefix <> _ = ref} = schema, document, depth)
       when depth < @max_depth do
    with true <- only_reference?(schema),
         {:ok, %{} = target} <- resolve(document, ref) do
      read_through(target, document, depth + 1)
    else
      _other -> schema
    end
  end

  defp read_through(%{} = schema, _document, _depth), do: schema
  defp read_through(_schema, _document, _depth), do: nil

  defp only_reference?(schema), do: schema |> Map.keys() |> Enum.all?(&(&1 in @annotations))

  @doc "The top-level `properties` of a schema, read through."
  @spec properties(term(), map()) :: map()
  def properties(schema, document) do
    case read_through(schema, document) do
      %{"properties" => %{} = properties} -> properties
      _other -> %{}
    end
  end

  @doc "The top-level `required` names of a schema, read through."
  @spec required(term(), map()) :: list()
  def required(schema, document) do
    case read_through(schema, document) do
      %{"required" => required} when is_list(required) -> required
      _other -> []
    end
  end

  @doc "The top-level `type` of a schema, read through."
  @spec type(term(), map()) :: term()
  def type(schema, document) do
    case read_through(schema, document) do
      %{"type" => type} -> type
      _other -> nil
    end
  end

  @doc "The description of a schema, its own or its read-through target's."
  @spec description(term(), map()) :: String.t() | nil
  def description(%{"description" => description}, _document) when is_binary(description),
    do: description

  def description(schema, document) do
    case read_through(schema, document) do
      %{"description" => description} when is_binary(description) -> description
      _other -> nil
    end
  end

  @doc """
  Checks every `$ref`, `$dynamicRef` and `$id` in a schema, returning issues
  with pointers under `path`.
  """
  @spec reference_issues(term(), [String.t()], map()) :: [Issue.t()]
  def reference_issues(schema, path, document) do
    schema
    |> fold(path, [], fn node, node_path, acc -> node_issues(node, node_path, document) ++ acc end)
    |> Enum.reverse()
  end

  defp node_issues(node, path, document) do
    id_issues =
      if Map.has_key?(node, "$id"),
        do: [issue(path ++ ["$id"], :invalid_reference, "$id is not allowed in profile schemas")],
        else: []

    ref_issues =
      for keyword <- @ref_keywords,
          ref = node[keyword],
          is_binary(ref),
          issue = ref_issue(ref, path ++ [keyword], document),
          do: issue

    id_issues ++ ref_issues
  end

  defp ref_issue(@prefix <> _ = ref, path, document) do
    case resolve(document, ref) do
      {:ok, _target} -> nil
      :error -> issue(path, :unresolved_reference, "#{ref} does not resolve")
    end
  end

  defp ref_issue("#" <> _ = ref, path, _document),
    do: issue(path, :invalid_reference, "#{ref} must point into #/components/schemas/")

  defp ref_issue(ref, path, _document),
    do: issue(path, :external_reference, "external reference #{ref} is not allowed")

  @doc """
  The names of the components a schema reaches, directly or through other
  components, sorted.
  """
  @spec reachable(term(), map()) :: [String.t()]
  def reachable(schema, components) do
    schema
    |> component_refs()
    |> walk_components(components, MapSet.new())
    |> Enum.sort()
  end

  defp walk_components([], _components, seen), do: seen

  defp walk_components([name | rest], components, seen) do
    if MapSet.member?(seen, name) or not Map.has_key?(components, name) do
      walk_components(rest, components, seen)
    else
      walk_components(
        component_refs(components[name]) ++ rest,
        components,
        MapSet.put(seen, name)
      )
    end
  end

  defp component_refs(schema) do
    fold(schema, [], [], fn node, _path, acc ->
      for keyword <- @ref_keywords,
          @prefix <> rest <- [node[keyword]],
          reduce: acc do
        acc -> [component_name(rest) | acc]
      end
    end)
  end

  defp component_name(rest) do
    rest |> decode() |> String.split("/", parts: 2) |> hd() |> unescape()
  end

  @doc """
  Bundles a schema with the components it reaches under `$defs`. A schema
  that reaches no component is returned unchanged.
  """
  @spec bundle(term(), [String.t()], map()) :: term()
  def bundle(schema, [], _components), do: schema

  def bundle(schema, names, components) do
    defs =
      names
      |> Map.new(fn name -> {name, rewrite(components[name])} end)
      |> Map.put(@root_def, rewrite(schema))

    %{"$defs" => defs, "$ref" => "#/$defs/" <> @root_def}
  end

  defp rewrite(schema) do
    transform(schema, fn node -> Enum.reduce(@ref_keywords, node, &rewrite_ref/2) end)
  end

  defp rewrite_ref(keyword, node) do
    case node do
      %{^keyword => @prefix <> rest} -> Map.put(node, keyword, "#/$defs/" <> rest)
      _other -> node
    end
  end

  # Folds over every schema object in `schema`, visiting only schema
  # positions (never `const`, `enum`, `examples` or unknown keywords).
  defp fold(%{} = schema, path, acc, fun) do
    acc = fun.(schema, path, acc)

    Enum.reduce(schema, acc, fn {keyword, value}, acc ->
      fold_keyword(keyword, value, path ++ [keyword], acc, fun)
    end)
  end

  defp fold(_schema, _path, acc, _fun), do: acc

  defp fold_keyword(keyword, %{} = value, path, acc, fun) when keyword in @map_keywords do
    Enum.reduce(value, acc, fn {name, schema}, acc -> fold(schema, path ++ [name], acc, fun) end)
  end

  defp fold_keyword(keyword, value, path, acc, fun)
       when keyword in @list_keywords and is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {schema, index}, acc -> fold(schema, path ++ [index], acc, fun) end)
  end

  defp fold_keyword(keyword, value, path, acc, fun) when keyword in @single_keywords,
    do: fold(value, path, acc, fun)

  defp fold_keyword(_keyword, _value, _path, acc, _fun), do: acc

  defp transform(%{} = schema, fun) do
    schema
    |> Map.new(fn {keyword, value} -> {keyword, transform_keyword(keyword, value, fun)} end)
    |> fun.()
  end

  defp transform(schema, _fun), do: schema

  defp transform_keyword(keyword, %{} = value, fun) when keyword in @map_keywords,
    do: Map.new(value, fn {name, schema} -> {name, transform(schema, fun)} end)

  defp transform_keyword(keyword, value, fun) when keyword in @list_keywords and is_list(value),
    do: Enum.map(value, &transform(&1, fun))

  defp transform_keyword(keyword, value, fun) when keyword in @single_keywords,
    do: transform(value, fun)

  defp transform_keyword(_keyword, value, _fun), do: value

  defp resolve(document, "#" <> fragment), do: JSON.resolve(document, decode(fragment))

  # `$ref` values are URI references, so their fragments are percent-encoded.
  defp decode(fragment) do
    URI.decode(fragment)
  rescue
    ArgumentError -> fragment
  end

  defp unescape(segment) do
    segment |> String.replace("~1", "/") |> String.replace("~0", "~")
  end

  defp issue(path, code, message), do: Issue.new(JSON.pointer(path), code, message)
end
