defmodule Tama.Dex.Index.SQLTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Tama.Dex.Index.SQL

  setup do
    {:ok, conn} = Sqlite3.open(":memory:")
    :ok = SQL.execute!(conn, "CREATE TABLE t (v INTEGER)")
    on_exit(fn -> Sqlite3.close(conn) end)
    %{conn: conn}
  end

  defp count(conn), do: SQL.query!(conn, "SELECT count(*) FROM t")

  test "a transaction commits or rolls back on request", %{conn: conn} do
    assert SQL.transaction(conn, fn ->
             {:commit, SQL.insert!(conn, "INSERT INTO t VALUES (?)", [1])}
           end) == 1

    assert SQL.transaction(conn, fn ->
             {:rollback, SQL.run!(conn, "INSERT INTO t VALUES (?)", [2])}
           end) == :ok

    assert count(conn) == [[1]]
  end

  test "a transaction rolls back when its function raises or throws", %{conn: conn} do
    assert_raise RuntimeError, fn ->
      SQL.transaction(conn, fn ->
        SQL.run!(conn, "INSERT INTO t VALUES (?)", [1])
        raise "boom"
      end)
    end

    assert catch_throw(
             SQL.transaction(conn, fn ->
               SQL.run!(conn, "INSERT INTO t VALUES (?)", [1])
               throw(:stop)
             end)
           ) == :stop

    assert count(conn) == [[0]]
    assert {:ok, :idle} = Sqlite3.transaction_status(conn)
  end

  test "a raise after the transaction ended leaves none open", %{conn: conn} do
    assert_raise SQL.Error, fn ->
      SQL.transaction(conn, fn ->
        SQL.execute!(conn, "COMMIT")
        raise SQL.Error, message: "after commit"
      end)
    end

    assert {:ok, :idle} = Sqlite3.transaction_status(conn)
  end

  test "SQLite errors raise SQL.Error", %{conn: conn} do
    assert_raise SQL.Error, ~r/no such table/, fn -> SQL.execute!(conn, "DELETE FROM missing") end
    assert_raise SQL.Error, ~r/no such table/, fn -> SQL.query!(conn, "SELECT * FROM missing") end

    assert_raise SQL.Error, ~r/malformed JSON/, fn ->
      SQL.query!(conn, "SELECT json(?)", ["{"])
    end
  end

  test "booleans are stored as integers", %{conn: conn} do
    :ok = SQL.run!(conn, "INSERT INTO t VALUES (?), (?)", [true, false])
    assert SQL.query!(conn, "SELECT v FROM t ORDER BY v") == [[0], [1]]
  end
end
