defmodule Tama.Dex.Index.Worker do
  @moduledoc false

  # Owns one SQLite connection and runs jobs on it one at a time.
  #
  # The index starts two workers, linked to it: a reader for queries and a
  # writer for loads and imports. A job is a function of the connection, or,
  # for a tracked load or import, of the connection and its
  # `Tama.Dex.Index.Job`.
  #
  # Read results go straight to the caller. Write results go back to the
  # index, which updates its state before replying, so a caller never sees
  # a reply ahead of the index's own view.
  #
  # An exception or exit in a job is caught and re-raised in the caller, so
  # a bad job never takes the index down.

  use GenServer

  alias Tama.Dex.Index.Connection
  alias Tama.Dex.Index.Store

  @doc false
  def start_link({role, location}) do
    GenServer.start_link(__MODULE__, {role, location})
  end

  @impl GenServer
  def init({:writer, location}) do
    Process.flag(:trap_exit, true)

    case Connection.open_writer(location) do
      {:ok, conn, schema} -> {:ok, %{role: :writer, conn: conn, schema: schema}}
      {:error, reason} -> {:stop, reason}
    end
  end

  def init({:reader, location}) do
    Process.flag(:trap_exit, true)

    case Connection.open_reader(location) do
      {:ok, conn} -> {:ok, %{role: :reader, conn: conn}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:schema, _from, state), do: {:reply, Map.get(state, :schema), state}

  def handle_call(:cassette_names, _from, state),
    do: {:reply, Store.cassette_names(state.conn), state}

  @impl GenServer
  def handle_info({:read, from, job}, %{role: :reader} = state) do
    GenServer.reply(from, run(job, state.conn))
    {:noreply, state}
  end

  def handle_info({:write, from, job, index, tracked}, %{role: :writer} = state) do
    result =
      case tracked do
        nil -> run(job, state.conn)
        tracked -> run(&job.(&1, %{tracked | index: index}), state.conn)
      end

    send(index, {:written, from, result, referenced(result, state.conn), tracked})
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Connection.close(state.conn)
  end

  defp run(job, conn) do
    {:ok, job.(conn)}
  rescue
    exception -> {:raise, exception, __STACKTRACE__}
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end

  # After a committed change, the schema digests rows still reference, so
  # the index can drop compiled schemas nothing uses, and the committed
  # cassettes, for the index's readiness.
  defp referenced({:ok, {:changed, _reply}}, conn) do
    {:ok, Store.schema_digests(conn), Store.cassette_names(conn)}
  end

  defp referenced(_result, _conn), do: :unchanged
end
