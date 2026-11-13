defmodule Tama.Dex.Search do
  @moduledoc false

  # Scope-filtered full-text search and describe over the index.
  #
  # Caller text never reaches SQLite as FTS5 syntax: it is reduced to
  # letter-and-digit terms, each quoted with a prefix wildcard and joined
  # with AND. Visibility is applied in SQL, so hidden operations never
  # affect ranking, counts or flags.

  alias Tama.Dex.Index.SQL

  @max_query_bytes 512
  @max_description 1024
  @budget 64 * 1024
  @default_limit 5
  @max_limit 20

  @columns """
  o.cassette, c.version, o.operation_id, o.source, o.summary, o.description, o.tags,
  o.scopes, o.destructive, o.deprecated, o.confirmation, o.bounds, o.input_schema
  """

  @detail_columns """
  o.identity, o.success_schema, o.error_schema, o.extensions
  """

  @doc "Checks search arguments, raising `ArgumentError` for invalid ones."
  @spec options!(term(), keyword()) :: map()
  def options!(query, opts) when is_list(opts) do
    %{
      text: query!(query),
      scopes: scopes!(Keyword.get(opts, :scopes)),
      limit: limit!(Keyword.get(opts, :limit, @default_limit)),
      cassette: optional!(opts, :cassette, &Tama.Dex.cassette!/1),
      source: optional!(opts, :source, &string!(&1, :source)),
      tags: tags!(Keyword.get(opts, :tags, [])),
      include_deprecated: boolean!(opts, :include_deprecated, false),
      include_destructive: boolean!(opts, :include_destructive, true),
      include_schemas: boolean!(opts, :include_schemas, true)
    }
  end

  defp query!(nil), do: ""

  defp query!(query) when is_binary(query) do
    if byte_size(query) > @max_query_bytes do
      raise ArgumentError, "the search query is over #{@max_query_bytes} bytes"
    end

    unless String.valid?(query), do: raise(ArgumentError, "the search query must be UTF-8")
    query
  end

  defp query!(query),
    do: raise(ArgumentError, "the search query must be a string, got: #{inspect(query)}")

  @doc false
  @spec scopes!(term()) :: [String.t()]
  def scopes!(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1) do
      scopes
    else
      raise ArgumentError, ":scopes must be a list of strings"
    end
  end

  def scopes!(nil), do: raise(ArgumentError, ":scopes is required, the caller's verified scopes")
  def scopes!(_scopes), do: raise(ArgumentError, ":scopes must be a list of strings")

  defp limit!(limit) when is_integer(limit) and limit in 1..@max_limit, do: limit

  defp limit!(limit) do
    raise ArgumentError,
          ":limit must be an integer from 1 to #{@max_limit}, got: #{inspect(limit)}"
  end

  defp optional!(opts, key, check) do
    case Keyword.get(opts, key) do
      nil -> nil
      value -> check.(value)
    end
  end

  defp string!(value, _key) when is_binary(value), do: value

  defp string!(value, key),
    do: raise(ArgumentError, ":#{key} must be a string, got: #{inspect(value)}")

  defp tags!(tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1),
      do: Enum.uniq(tags),
      else: raise(ArgumentError, ":tags must be a list of strings")
  end

  defp tags!(_tags), do: raise(ArgumentError, ":tags must be a list of strings")

  defp boolean!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      value -> raise ArgumentError, ":#{key} must be a boolean, got: #{inspect(value)}"
    end
  end

  @doc """
  The FTS5 query for caller text: letter-and-digit terms, each quoted with a
  prefix wildcard, joined with AND. `nil` when the text has no term.
  """
  @spec match_expression(String.t()) :: String.t() | nil
  def match_expression(text) do
    case terms(text) do
      [] -> nil
      terms -> Enum.map_join(terms, " AND ", &~s("#{&1}"*))
    end
  end

  defp terms(text) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "Runs a search on the read connection."
  @spec search(SQL.conn(), map()) :: %{results: [map()], truncated: boolean()}
  def search(conn, options) do
    {filters, filter_args} = filters(options)

    rows =
      case match_expression(options.text) do
        nil ->
          SQL.query!(
            conn,
            """
            SELECT #{@columns}
            FROM operations o JOIN cassettes c ON c.cassette = o.cassette
            WHERE #{filters}
            ORDER BY o.cassette, o.operation_id
            LIMIT ?
            """,
            filter_args ++ [options.limit]
          )

        expression ->
          SQL.query!(
            conn,
            """
            SELECT #{@columns}
            FROM operations_fts f
            JOIN operations o ON o.id = f.rowid
            JOIN cassettes c ON c.cassette = o.cassette
            WHERE operations_fts MATCH ? AND #{filters}
            ORDER BY o.operation_id = ? DESC,
                     bm25(operations_fts, 10.0, 5.0, 3.0, 1.0, 1.0),
                     o.cassette, o.operation_id
            LIMIT ?
            """,
            [expression | filter_args] ++
              [String.downcase(String.trim(options.text)), options.limit]
          )
      end

    rows
    |> Enum.map(&result(&1, options.include_schemas))
    |> fit()
  end

  defp filters(options) do
    [
      {visible_clause(), [Jason.encode!(options.scopes)]},
      options.cassette && {"o.cassette = ?", [options.cassette]},
      options.source && {"o.source = ?", [options.source]},
      options.tags != [] &&
        {"(SELECT count(DISTINCT t.value) FROM json_each(o.tags) t
           WHERE t.value IN (SELECT value FROM json_each(?))) = ?",
         [Jason.encode!(options.tags), length(options.tags)]},
      not options.include_deprecated && {"o.deprecated = 0", []},
      not options.include_destructive && {"o.destructive = 0", []}
    ]
    |> Enum.filter(& &1)
    |> Enum.reduce({[], []}, fn {clause, args}, {clauses, all} ->
      {[clause | clauses], all ++ args}
    end)
    |> then(fn {clauses, args} -> {clauses |> Enum.reverse() |> Enum.join(" AND "), args} end)
  end

  @doc false
  # Visible when every one of the operation's scopes is among the caller's.
  # Takes one argument: the caller's scopes as a JSON array.
  @spec visible_clause() :: String.t()
  def visible_clause do
    """
    NOT EXISTS (SELECT 1 FROM json_each(o.scopes) s
                WHERE s.value NOT IN (SELECT value FROM json_each(?)))
    """
  end

  defp result(row, include_schemas) do
    [
      cassette,
      version,
      id,
      source,
      summary,
      description,
      tags,
      scopes,
      destructive,
      deprecated,
      confirmation,
      bounds,
      input_schema
    ] = row

    {description, truncated} = truncate(description)

    base = %{
      cassette: cassette,
      cassette_version: version,
      operation_id: id,
      source: source,
      summary: summary,
      description: description,
      description_truncated: truncated,
      tags: Jason.decode!(tags),
      scopes: Jason.decode!(scopes),
      destructive: destructive == 1,
      deprecated: deprecated == 1,
      confirmation: confirmation(confirmation),
      bounds: decode(bounds, %{})
    }

    if include_schemas, do: Map.put(base, :input_schema, Jason.decode!(input_schema)), else: base
  end

  defp truncate(description) do
    if String.length(description) > @max_description,
      do: {String.slice(description, 0, @max_description), true},
      else: {description, false}
  end

  defp confirmation(nil), do: nil

  defp confirmation(text) do
    %{"field" => field, "description" => description} = Jason.decode!(text)
    %{field: field, description: description}
  end

  defp decode(nil, default), do: default
  defp decode(text, _default), do: Jason.decode!(text)

  # Keeps the encoded response within the budget: drops input schemas from
  # the lowest-ranked results first, then whole results from the end. Each
  # result is encoded once to size it; the response is the results joined by
  # commas inside a fixed envelope.
  defp fit(results) do
    sized = Enum.map(results, &{&1, encoded_size(&1)})

    {reversed, _total} =
      sized
      |> Enum.reverse()
      |> Enum.map_reduce(total(sized), fn {result, size}, total ->
        if total > @budget and Map.has_key?(result, :input_schema) do
          omitted = result |> Map.delete(:input_schema) |> Map.put(:schema_omitted, true)
          omitted_size = encoded_size(omitted)
          {{omitted, omitted_size}, total - size + omitted_size}
        else
          {{result, size}, total}
        end
      end)

    drop_results(Enum.reverse(reversed), false)
  end

  defp drop_results(sized, truncated) do
    if total(sized) <= @budget do
      %{results: Enum.map(sized, &elem(&1, 0)), truncated: truncated}
    else
      drop_results(Enum.drop(sized, -1), true)
    end
  end

  @envelope byte_size(~s({"results":[],"truncated":false}))

  defp total([]), do: @envelope

  defp total(sized) do
    @envelope + Enum.sum_by(sized, &elem(&1, 1)) + length(sized) - 1
  end

  defp encoded_size(result), do: byte_size(Jason.encode!(result))

  @doc "One visible operation in full, or `nil`."
  @spec describe(SQL.conn(), String.t(), String.t(), [String.t()]) :: map() | nil
  def describe(conn, cassette, operation_id, scopes) do
    case SQL.query!(
           conn,
           """
           SELECT #{@columns}, #{@detail_columns}
           FROM operations o JOIN cassettes c ON c.cassette = o.cassette
           WHERE o.cassette = ? AND o.operation_id = ? AND #{visible_clause()}
           """,
           [cassette, operation_id, Jason.encode!(scopes)]
         ) do
      [row] -> detail(row)
      [] -> nil
    end
  end

  defp detail(row) do
    {base, [identity, success_schema, error_schema, extensions]} = Enum.split(row, 13)
    [_cassette, _version, _id, _source, _summary, description | _rest] = base

    base
    |> result(true)
    |> Map.merge(%{
      description: description,
      description_truncated: false,
      identity: decode(identity, []),
      success_schema: Jason.decode!(success_schema),
      error_schema: decode(error_schema, nil),
      extensions: decode(extensions, %{})
    })
  end
end
