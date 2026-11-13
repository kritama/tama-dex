defmodule Tama.Dex.Index.SQL do
  @moduledoc false

  # Thin helpers over exqlite. Failures raise `Tama.Dex.Index.SQL.Error`,
  # whose message is SQLite's, never a bound value.

  alias Exqlite.Sqlite3

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @type conn :: Sqlite3.db()

  @doc "Runs one or more statements that take no arguments."
  @spec execute!(conn(), String.t()) :: :ok
  def execute!(conn, sql) do
    case Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> raise Error, message: to_string(reason)
    end
  end

  @doc "Runs a query and returns every row."
  @spec query!(conn(), String.t(), list()) :: [list()]
  def query!(conn, sql, args \\ []) do
    with_statement(conn, sql, args, fn statement ->
      case Sqlite3.fetch_all(conn, statement) do
        {:ok, rows} -> rows
        {:error, reason} -> raise Error, message: to_string(reason)
      end
    end)
  end

  @doc "Runs a statement for its effect."
  @spec run!(conn(), String.t(), list()) :: :ok
  def run!(conn, sql, args \\ []) do
    _rows = query!(conn, sql, args)
    :ok
  end

  @doc "Runs an insert and returns the new row's ID."
  @spec insert!(conn(), String.t(), list()) :: integer()
  def insert!(conn, sql, args) do
    :ok = run!(conn, sql, args)
    {:ok, id} = Sqlite3.last_insert_rowid(conn)
    id
  end

  @doc """
  Runs `fun` in an immediate transaction. It commits when `fun` returns
  `{:commit, value}` and rolls back when it returns `{:rollback, value}` or
  raises, returning `value`.
  """
  @spec transaction(conn(), (-> {:commit, term()} | {:rollback, term()})) :: term()
  def transaction(conn, fun) do
    execute!(conn, "BEGIN IMMEDIATE")

    try do
      case fun.() do
        {:commit, value} ->
          execute!(conn, "COMMIT")
          value

        {:rollback, value} ->
          execute!(conn, "ROLLBACK")
          value
      end
    rescue
      exception ->
        rollback(conn)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        rollback(conn)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp rollback(conn) do
    case Sqlite3.transaction_status(conn) do
      {:ok, :transaction} -> Sqlite3.execute(conn, "ROLLBACK")
      _idle -> :ok
    end
  end

  defp with_statement(conn, sql, args, fun) do
    statement =
      case Sqlite3.prepare(conn, sql) do
        {:ok, statement} -> statement
        {:error, reason} -> raise Error, message: to_string(reason)
      end

    try do
      :ok = Sqlite3.bind(statement, Enum.map(args, &value/1))
      fun.(statement)
    after
      Sqlite3.release(conn, statement)
    end
  end

  defp value(true), do: 1
  defp value(false), do: 0
  defp value(other), do: other
end
