defmodule Tama.Dex.Search do
  @moduledoc false

  # Scope-filtered full-text search and describe over the index.
  #
  # Caller text never reaches SQLite as FTS5 syntax: it is reduced to runs
  # of letters, digits and combining marks, each quoted with a prefix
  # wildcard and joined with AND. Inside the quotes FTS5 tokenizes the run
  # itself, with the index's own tokenizer, so a query term always folds and
  # splits exactly as the indexed text does. FTS5 decides which operations
  # match. The visibility filter and the caller's other filters are applied
  # in SQL, so hidden operations never affect counts or flags.
  #
  # Ranking is computed here rather than with FTS5's bm25(), whose
  # statistics cover the whole table, hidden operations included. The same
  # Okapi BM25 is computed over the candidates alone, the operations this
  # search could return: their count, their mean length and, for each term,
  # how many of them match it. Every figure comes from FTS5, so nothing here
  # re-implements its tokenizer: lengths from its per-row token counts in
  # `operations_fts_docsize`, and term frequencies from counting the
  # matches highlight() marks in each column.

  alias Tama.Dex.Index.SQL

  @max_query_bytes 512
  @max_description 1024
  @budget 64 * 1024
  @default_limit 5
  @max_limit 20

  # Column weights, in FTS column order (operation_id, summary, tags,
  # description, fields), and FTS5's BM25 parameters.
  @weights [10.0, 5.0, 3.0, 1.0, 1.0]
  @k1 1.2
  @b 0.75

  # The marker highlight() puts before each term match. A single code
  # point, so the matches are the marker count less the text's own.
  @marker "\u0001"

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
  The FTS5 query for caller text: runs of letters, digits and combining
  marks, each quoted with a prefix wildcard, joined with AND. `nil` when the
  text has no term. FTS5 tokenizes each quoted run, so a run it splits
  becomes a phrase whose last token is the prefix.
  """
  @spec match_expression(String.t()) :: String.t() | nil
  def match_expression(text) do
    case terms(text) do
      [] -> nil
      terms -> Enum.map_join(terms, " AND ", &~s("#{&1}"*))
    end
  end

  # A run starts with a letter, digit or private-use character, the
  # characters unicode61 indexes, and keeps any combining marks within it,
  # so a word such as "हिन्दी" stays one phrase. Runs equal but for case are
  # one term, since FTS5 folds case.
  defp terms(text) do
    ~r/[\p{L}\p{N}\p{Co}][\p{L}\p{N}\p{M}\p{Co}]*/u
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.uniq_by(&String.downcase/1)
  end

  @doc """
  Runs a search on the read connection, in one read transaction so the
  ranking statistics and the matches come from the same state.
  """
  @spec search(SQL.conn(), map()) :: %{results: [map()], truncated: boolean()}
  def search(conn, options), do: SQL.read_transaction(conn, fn -> run(conn, options) end)

  defp run(conn, options) do
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
          conn
          |> ranked_ids(expression, {filters, filter_args}, options)
          |> rows_by_id(conn)
      end

    rows
    |> Enum.map(&result(&1, options.include_schemas))
    |> fit()
  end

  # The IDs of the best `limit` matches: an exact operationId match first,
  # then by score, then by cassette and operationId.
  defp ranked_ids(conn, expression, {filters, args}, options) do
    case matched(conn, expression, filters, args) do
      [] ->
        []

      matched ->
        scores = scores(conn, matched, filters, args, terms(options.text))
        exact = String.downcase(String.trim(options.text))

        matched
        |> Enum.map(&sort_key(&1, scores, exact))
        |> Enum.sort()
        |> Enum.take(options.limit)
        |> Enum.map(&elem(&1, 1))
    end
  end

  defp sort_key({id, cassette, operation_id, _length}, scores, exact) do
    rank = if operation_id == exact, do: 0, else: 1
    {{rank, -Map.fetch!(scores, id), cassette, operation_id}, id}
  end

  # The candidates matching every term, with their lengths.
  defp matched(conn, expression, filters, args) do
    conn
    |> SQL.query!(
      """
      SELECT o.id, o.cassette, o.operation_id, d.sz
      FROM operations_fts f
      JOIN operations o ON o.id = f.rowid
      JOIN cassettes c ON c.cassette = o.cassette
      JOIN operations_fts_docsize d ON d.id = f.rowid
      WHERE operations_fts MATCH ? AND #{filters}
      """,
      [expression | args]
    )
    |> Enum.map(fn [id, cassette, operation_id, size] ->
      {id, cassette, operation_id, token_total(size)}
    end)
  end

  # Each matched operation's BM25 score, keyed by ID.
  defp scores(conn, matched, filters, args, terms) do
    {count, mean} = candidates(conn, filters, args)
    ids = Jason.encode!(Enum.map(matched, &elem(&1, 0)))

    per_term =
      Enum.map(terms, fn term ->
        expression = ~s("#{term}"*)
        {idf(count, matches(conn, expression, filters, args)), frequencies(conn, expression, ids)}
      end)

    Map.new(matched, fn {id, _cassette, _operation_id, length} ->
      norm = @k1 * (1 - @b + @b * length / mean)

      score =
        Enum.reduce(per_term, 0.0, fn {idf, frequencies}, score ->
          frequency = Map.get(frequencies, id, 0.0)
          score + idf * frequency * (@k1 + 1) / (frequency + norm)
        end)

      {id, score}
    end)
  end

  # The candidates' count and mean length, at least 1.
  defp candidates(conn, filters, args) do
    lengths =
      conn
      |> SQL.query!(
        """
        SELECT d.sz
        FROM operations o
        JOIN cassettes c ON c.cassette = o.cassette
        JOIN operations_fts_docsize d ON d.id = o.id
        WHERE #{filters}
        """,
        args
      )
      |> Enum.map(fn [size] -> token_total(size) end)

    count = length(lengths)
    {count, if(count == 0, do: 1.0, else: max(Enum.sum(lengths) / count, 1.0))}
  end

  defp matches(conn, expression, filters, args) do
    [[count]] =
      SQL.query!(
        conn,
        """
        SELECT count(*)
        FROM operations_fts f
        JOIN operations o ON o.id = f.rowid
        JOIN cassettes c ON c.cassette = o.cassette
        WHERE operations_fts MATCH ? AND #{filters}
        """,
        [expression | args]
      )

    count
  end

  # One term's column-weighted frequency in each matched operation, keyed
  # by ID: the matches highlight() marks in each column, weighted.
  defp frequencies(conn, expression, ids) do
    marked = Enum.map_join(0..4, ", ", &"highlight(operations_fts, #{&1}, '#{@marker}', '')")

    conn
    |> SQL.query!(
      """
      SELECT f.rowid, #{marked}, f.operation_id, f.summary, f.tags, f.description, f.fields
      FROM operations_fts f
      WHERE operations_fts MATCH ? AND f.rowid IN (SELECT value FROM json_each(?))
      """,
      [expression, ids]
    )
    |> Map.new(fn [id | columns] ->
      {highlighted, texts} = Enum.split(columns, 5)

      frequency =
        [highlighted, texts, @weights]
        |> Enum.zip()
        |> Enum.reduce(0.0, fn {marked, text, weight}, sum ->
          sum + weight * (markers(marked) - markers(text))
        end)

      {id, frequency}
    end)
  end

  defp markers(text), do: length(:binary.matches(text, @marker))

  # FTS5's inverse document frequency, floored just above zero.
  defp idf(count, matches) do
    ratio = (count - matches + 0.5) / (matches + 0.5)
    if ratio > 1.0, do: :math.log(ratio), else: 1.0e-6
  end

  # An operation's token count across its FTS columns, from its
  # operations_fts_docsize blob: one SQLite varint per column.
  @doc false
  @spec token_total(binary()) :: non_neg_integer()
  def token_total(size), do: varints(size, 0)

  # SQLite's varint: big-endian groups of 7 bits, each byte but the last
  # with its high bit set, and a ninth byte that holds 8 bits.
  defp varints(<<>>, total), do: total

  defp varints(bytes, total) do
    {value, rest} = varint(bytes, 0, 1)
    varints(rest, total + value)
  end

  defp varint(<<byte, rest::binary>>, value, 9), do: {value * 256 + byte, rest}
  defp varint(<<0::1, low::7, rest::binary>>, value, _n), do: {value * 128 + low, rest}

  defp varint(<<1::1, low::7, rest::binary>>, value, n),
    do: varint(rest, value * 128 + low, n + 1)

  defp rows_by_id([], _conn), do: []

  defp rows_by_id(ids, conn) do
    rows =
      SQL.query!(
        conn,
        """
        SELECT o.id, #{@columns}
        FROM operations o JOIN cassettes c ON c.cassette = o.cassette
        WHERE o.id IN (SELECT value FROM json_each(?))
        """,
        [Jason.encode!(ids)]
      )
      |> Map.new(fn [id | row] -> {id, row} end)

    Enum.map(ids, &Map.fetch!(rows, &1))
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
