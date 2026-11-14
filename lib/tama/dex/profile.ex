defmodule Tama.Dex.Profile do
  @moduledoc """
  Validates documents in the Tama operations profile, `tama-operations/1`.

  The profile is defined in `docs/tama-operations-profile.md`, and its
  document shape is published as JSON Schema 2020-12 in
  `priv/profile/tama-operations-1.schema.json`.

  `validate/1` is pure: it starts no process and reads no file or network
  resource. Producers can use it as a test-only dependency to check their
  documents.
  """

  alias Tama.Dex.Document
  alias Tama.Dex.JSON
  alias Tama.Dex.Operation
  alias Tama.Dex.Profile.Issue
  alias Tama.Dex.Profile.Schemas

  @profile "tama-operations/1"
  @schema_path Path.expand("../../../priv/profile/tama-operations-1.schema.json", __DIR__)
  @external_resource @schema_path
  @json_schema @schema_path |> File.read!() |> Jason.decode!()

  @limits [
    max_document_bytes: 4 * 1024 * 1024,
    max_operations: 1024,
    max_schema_bytes: 256 * 1024
  ]
  @max_extension_bytes 16 * 1024
  @max_json_issues 32

  @doc "The profile version this module validates, `#{@profile}`."
  @spec profile() :: String.t()
  def profile, do: @profile

  @doc "The profile's published JSON Schema, as decoded JSON."
  @spec json_schema() :: map()
  def json_schema, do: @json_schema

  @doc """
  The profile's limits: `max_document_bytes` (4 MiB), `max_operations`
  (1024) and `max_schema_bytes` (256 KiB).
  """
  @spec limits() :: keyword(pos_integer())
  def limits, do: @limits

  @doc false
  # Checks host-supplied limits, which may only lower the profile's, and
  # returns the full set.
  @spec limits!(keyword()) :: keyword(pos_integer())
  def limits!(overrides) when is_list(overrides) do
    Enum.reduce(overrides, @limits, fn
      {key, value}, limits when is_integer(value) and value > 0 ->
        case Keyword.fetch(@limits, key) do
          {:ok, max} when value <= max ->
            Keyword.put(limits, key, value)

          {:ok, max} ->
            raise ArgumentError, "limit #{key} can't exceed the profile's #{max}"

          :error ->
            raise ArgumentError, "unknown limit #{inspect(key)}"
        end

      other, _limits ->
        raise ArgumentError, "limits must be positive integers, got: #{inspect(other)}"
    end)
  end

  def limits!(other) do
    raise ArgumentError, "limits must be a keyword list, got: #{inspect(other)}"
  end

  @doc """
  Validates a profile document given as decoded JSON (a map with string keys).

  Returns `{:ok, document}` with the normalized `Tama.Dex.Document`, or
  `{:error, issues}` listing every issue found, ordered by pointer. See
  `Tama.Dex.Profile.Issue` for the codes.

  Checks run in this order, and each of the first four stops validation when
  it fails:

  1. The document is JSON data.
  2. `x-tama-profile` is `#{@profile}`. Otherwise the only issue is
     `:unsupported_profile`, and no operation is read.
  3. The serialized document is at most 4 MiB and holds at most 1024
     operations. Otherwise no schema is compiled.

  The `:limits` option lowers the profile's limits, as a keyword list of
  `:max_document_bytes`, `:max_operations` and `:max_schema_bytes`. Limits
  above the profile's raise `ArgumentError`.
  4. The document's shape matches the profile's JSON Schema, and the
     semantic rules hold: path suffixes, unique IDs, confirmation and
     identity fields, references, sizes and schema compilation. Every issue
     from this step is reported together.
  """
  @spec validate(term(), keyword()) :: {:ok, Document.t()} | {:error, [Issue.t()]}
  def validate(document, opts \\ [])

  def validate(document, opts) when is_map(document) do
    limits = opts |> Keyword.get(:limits, []) |> limits!() |> Map.new()

    with :ok <- check_json(document),
         :ok <- check_profile(document),
         {:ok, canonical_json} <- check_limits(document, limits) do
      check_document(document, canonical_json, limits)
    end
  end

  def validate(_document, _opts) do
    {:error, [Issue.new("", :invalid_document, "a profile document must be a JSON object")]}
  end

  # JSON data

  defp check_json(document) do
    case document |> json_issues([], []) |> Enum.take(@max_json_issues) do
      [] -> :ok
      issues -> {:error, Enum.reverse(issues)}
    end
  end

  defp json_issues(_value, _path, acc) when length(acc) >= @max_json_issues, do: acc

  defp json_issues(map, path, acc) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, acc, fn
      {key, value}, acc when is_binary(key) ->
        if String.valid?(key),
          do: json_issues(value, path ++ [key], acc),
          else: [json_issue(path, "object keys must be UTF-8 strings") | acc]

      {_key, _value}, acc ->
        [json_issue(path, "object keys must be strings") | acc]
    end)
  end

  defp json_issues(list, path, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, acc -> json_issues(value, path ++ [index], acc) end)
  end

  defp json_issues(value, path, acc) when is_binary(value) do
    if String.valid?(value), do: acc, else: [json_issue(path, "strings must be UTF-8") | acc]
  end

  defp json_issues(value, _path, acc)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: acc

  defp json_issues(_value, path, acc), do: [json_issue(path, "value is not JSON data") | acc]

  defp json_issue(path, message), do: issue(path, :invalid_json, message)

  # Profile version

  defp check_profile(%{"x-tama-profile" => @profile}), do: :ok

  defp check_profile(_document) do
    {:error,
     [issue(["x-tama-profile"], :unsupported_profile, "x-tama-profile must be #{@profile}")]}
  end

  # Limits

  defp check_limits(document, limits) do
    canonical_json = JSON.encode!(document)

    issues =
      [
        byte_size(canonical_json) > limits.max_document_bytes &&
          issue(
            [],
            :document_too_large,
            "the serialized document is over #{limits.max_document_bytes} bytes"
          ),
        operation_count(document) > limits.max_operations &&
          issue(
            ["paths"],
            :too_many_operations,
            "the document holds over #{limits.max_operations} operations"
          )
      ]
      |> Enum.filter(& &1)

    if issues == [], do: {:ok, canonical_json}, else: {:error, issues}
  end

  defp operation_count(%{"paths" => %{} = paths}), do: map_size(paths)
  defp operation_count(_document), do: 0

  # Shape and semantics

  defp check_document(document, canonical_json, limits) do
    components = components(document)
    {component_issues, broken} = check_components(components, document)
    operations = operations(document)

    context = %{document: document, components: components, broken: broken, limits: limits}
    checked = Enum.map(operations, &check_operation(&1, context))

    issues =
      (shape_issues(document) ++
         component_issues ++
         duplicate_issues(operations) ++ Enum.flat_map(checked, &elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.pointer, &1.code})

    if issues == [] do
      {:ok, build(document, canonical_json, operations, Enum.map(checked, &elem(&1, 1)))}
    else
      {:error, issues}
    end
  end

  defp components(%{"components" => %{"schemas" => %{} = schemas}}), do: schemas
  defp components(_document), do: %{}

  defp check_components(components, document) do
    Enum.reduce(components, {[], MapSet.new()}, fn {name, schema}, {issues, broken} ->
      case Schemas.reference_issues(schema, ["components", "schemas", name], document) do
        [] -> {issues, broken}
        found -> {issues ++ found, MapSet.put(broken, name)}
      end
    end)
  end

  defp operations(%{"paths" => %{} = paths}) do
    for {path, %{"post" => %{} = operation}} <- Enum.sort(paths), do: {path, operation}
  end

  defp operations(_document), do: []

  defp shape_issues(document) do
    {:ok, schema} = JSONSchex.compile(@json_schema)

    case JSONSchex.validate(schema, document) do
      :ok -> []
      {:error, errors} -> Enum.flat_map(errors, &shape_issue/1)
    end
  end

  defp shape_issue(%{rule: :required, path: path, context: %{contrast: missing}}) do
    for name <- List.wrap(missing) do
      issue(Enum.reverse(path) ++ [name], :missing_field, "#{name} is required")
    end
  end

  defp shape_issue(%{rule: :boolean_schema, path: path}) do
    path = Enum.reverse(path)
    [unknown_issue(Enum.drop(path, -1), List.last(path), path)]
  end

  defp shape_issue(error) do
    message =
      error
      |> JSONSchex.format_error()
      |> String.replace(~r/^At [^:]*: /, "")
      |> String.replace(~r/Regex\.compile!\((".*")(?:, \[[^\]]*\])?\)/U, "\\1")

    [issue(Enum.reverse(error.path), :invalid_field, message)]
  end

  defp unknown_issue(_parent, "x-tama-" <> _ = key, path),
    do: issue(path, :unknown_extension, "#{key} is not defined by #{@profile}")

  defp unknown_issue(["paths"], key, path),
    do: issue(path, :invalid_path, "path #{key} must be /operations/{operationId}")

  defp unknown_issue([], "webhooks", path),
    do: issue(path, :unknown_field, "webhooks are not allowed")

  defp unknown_issue(_parent, key, path),
    do: issue(path, :unknown_field, "#{key} is not allowed here")

  defp duplicate_issues(operations) do
    operations
    |> Enum.filter(fn {_path, operation} -> is_binary(operation["operationId"]) end)
    |> Enum.group_by(fn {_path, operation} -> operation["operationId"] end)
    |> Enum.flat_map(fn {id, [_first | rest]} ->
      for {path, _operation} <- rest do
        issue(
          operation_path(path, ["operationId"]),
          :duplicate_operation_id,
          "#{id} is not unique"
        )
      end
    end)
  end

  defp check_operation({path, operation}, %{document: document} = context) do
    {schema_issues, schemas} = check_schemas(path, operation, context)

    issues =
      schema_issues ++
        id_issues(path, operation) ++
        extension_issues(path, operation) ++
        input_issues(path, operation, document) ++
        confirmation_issues(path, operation, document) ++
        identity_issues(path, operation, document)

    {issues, schemas}
  end

  defp id_issues("/operations/" <> suffix = path, %{"operationId" => id})
       when is_binary(id) and suffix != id do
    [
      issue(
        operation_path(path, ["operationId"]),
        :operation_id_mismatch,
        "operationId #{id} must equal the path suffix #{suffix}"
      )
    ]
  end

  defp id_issues(_path, _operation), do: []

  defp extension_issues(path, operation) do
    if operation |> extensions() |> JSON.encode!() |> byte_size() > @max_extension_bytes do
      [
        issue(
          operation_path(path, []),
          :extensions_too_large,
          "the operation's x- extensions are over 16 KiB"
        )
      ]
    else
      []
    end
  end

  defp extensions(operation) do
    for {"x-" <> _ = key, value} <- operation,
        not String.starts_with?(key, "x-tama-"),
        into: %{} do
      {key, value}
    end
  end

  defp input_issues(path, operation, document) do
    case input_schema(operation) do
      %{} = schema ->
        if Schemas.type(schema, document) == "object",
          do: [],
          else: [
            issue(
              operation_path(path, input_pointer()),
              :invalid_input_schema,
              "the request body schema must be an object schema (\"type\": \"object\")"
            )
          ]

      _other ->
        []
    end
  end

  defp confirmation_issues(path, operation, document) do
    with %{"field" => field} when is_binary(field) <- operation["x-tama-confirmation"],
         false <- confirmation_field?(field, input_schema(operation), document) do
      [
        issue(
          operation_path(path, ["x-tama-confirmation", "field"]),
          :invalid_confirmation,
          "#{field} must be a required top-level string property of the input schema"
        )
      ]
    else
      _other -> []
    end
  end

  defp confirmation_field?(field, schema, document) do
    property = Map.get(Schemas.properties(schema, document), field)

    field in Schemas.required(schema, document) and
      Schemas.type(property, document) in ["string", ["string"]]
  end

  defp identity_issues(path, %{"x-tama-identity" => names} = operation, document)
       when is_list(names) do
    declared =
      Map.merge(
        Schemas.properties(response_schema(operation, "default"), document),
        Schemas.properties(response_schema(operation, "200"), document)
      )

    for {name, index} <- Enum.with_index(names),
        is_binary(name),
        not Map.has_key?(declared, name) do
      issue(
        operation_path(path, ["x-tama-identity", index]),
        :invalid_identity,
        "#{name} must be a top-level property of the 200 or default schema"
      )
    end
  end

  defp identity_issues(_path, _operation, _document), do: []

  # Request and response schemas

  defp check_schemas(path, operation, context) do
    [
      {:input, input_pointer(), input_schema(operation)},
      {:success, response_pointer("200"), response_schema(operation, "200")},
      {:error, response_pointer("default"), response_schema(operation, "default")}
    ]
    |> Enum.reduce({[], %{}}, fn
      {key, pointer, %{} = schema}, {issues, bundled} ->
        location = operation_path(path, pointer)

        case check_schema(schema, location, context) do
          {:ok, schema} -> {issues, Map.put(bundled, key, schema)}
          {:error, found} -> {issues ++ found, bundled}
        end

      _absent, acc ->
        acc
    end)
  end

  defp check_schema(schema, location, context) do
    %{document: document, components: components, broken: broken, limits: limits} = context

    with :ok <- check_size(schema, location, limits),
         :ok <- check_references(schema, location, document),
         names = Schemas.reachable(schema, components),
         :ok <- check_broken(names, broken),
         bundled = Schemas.bundle(schema, names, components),
         :ok <- check_size(bundled, location, limits) do
      compile(bundled, location)
    end
  end

  defp check_size(schema, location, %{max_schema_bytes: max}) do
    if schema |> JSON.encode!() |> byte_size() > max do
      {:error,
       [
         issue(
           location,
           :schema_too_large,
           "the schema, with the components it references, is over #{max} bytes"
         )
       ]}
    else
      :ok
    end
  end

  defp check_references(schema, location, document) do
    case Schemas.reference_issues(schema, location, document) do
      [] -> :ok
      issues -> {:error, issues}
    end
  end

  # A component with a broken reference is reported once, at the component.
  defp check_broken(names, broken) do
    if Enum.any?(names, &MapSet.member?(broken, &1)), do: {:error, []}, else: :ok
  end

  defp compile(bundled, location) do
    case JSONSchex.compile(bundled, draft: "draft2020_12") do
      {:ok, _compiled} ->
        {:ok, bundled}

      {:error, error} ->
        {:error,
         [
           issue(
             location,
             :schema_compile_failed,
             "the schema does not compile: " <> JSONSchex.format_error(error)
           )
         ]}
    end
  end

  defp input_schema(operation), do: dig(operation, input_pointer())

  defp response_schema(operation, status), do: dig(operation, response_pointer(status))

  # Like get_in/2, but nil wherever the document has the wrong shape.
  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)
  defp dig(_value, _keys), do: nil

  defp input_pointer, do: ["requestBody", "content", "application/json", "schema"]

  defp response_pointer(status),
    do: ["responses", status, "content", "application/json", "schema"]

  defp operation_path(path, rest), do: ["paths", path, "post" | rest]

  # Normalization

  defp build(document, canonical_json, operations, schemas) do
    source = document["x-tama-source"]

    normalized =
      operations
      |> Enum.zip(schemas)
      |> Enum.map(fn {{_path, operation}, schemas} ->
        normalize(source, operation, schemas, document)
      end)
      |> Enum.sort_by(& &1.operation_id)

    %Document{
      profile: @profile,
      source: source,
      title: get_in(document, ["info", "title"]),
      version: get_in(document, ["info", "version"]),
      digest: JSON.sha256(canonical_json),
      canonical_json: canonical_json,
      operations: normalized
    }
  end

  defp normalize(source, operation, schemas, document) do
    %Operation{
      source: source,
      operation_id: operation["operationId"],
      summary: operation["summary"],
      description: operation["description"],
      tags: Map.get(operation, "tags", []),
      deprecated: Map.get(operation, "deprecated", false),
      scopes: operation["x-tama-scopes"],
      destructive: operation["x-tama-destructive"],
      confirmation: confirmation(operation["x-tama-confirmation"]),
      bounds: Map.get(operation, "x-tama-bounds", %{}),
      identity: Map.get(operation, "x-tama-identity", []),
      extensions: extensions(operation),
      fields: fields(input_schema(operation), document),
      input_schema: schemas.input,
      success_schema: schemas.success,
      error_schema: Map.get(schemas, :error)
    }
  end

  defp confirmation(%{"field" => field, "description" => description}),
    do: %{field: field, description: description}

  defp confirmation(nil), do: nil

  defp fields(schema, document) do
    schema
    |> Schemas.properties(document)
    |> Enum.sort_by(fn {name, _property} -> name end)
    |> Enum.map(fn {name, property} ->
      %{name: name, description: Schemas.description(property, document)}
    end)
  end

  defp issue(path, code, message), do: Issue.new(JSON.pointer(path), code, message)
end
