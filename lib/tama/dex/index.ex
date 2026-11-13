defmodule Tama.Dex.Index do
  @moduledoc """
  The SQLite index of operation documents.

  A host starts the index under its own supervisor, with an explicit
  database location, and passes it (a pid or registered name) into every
  `Tama.Dex` call. tama-dex has no application callback, so nothing is
  opened until a host starts an index.

      children = [
        {Tama.Dex.Index, path: "/var/lib/my_host/tama-dex.sqlite3", name: MyHost.Index}
      ]

  One index holds every cassette the host installs. Each cassette is a
  namespace inside it.

  ## Options

  - `:path` (required): a database file path, or `:memory`. A new file is
    created with mode 0600 and opened in WAL mode. Its directory must exist.
    `:memory` keeps the index in memory for the life of the process, which
    suits tests and short-lived hosts.
  - `:name` (optional): a name to register the index under.
  - `:limits` (optional): lower limits for documents loaded into this index,
    as a keyword list of `:max_document_bytes`, `:max_operations` and
    `:max_schema_bytes`. They can't exceed the profile's limits.

  ## Processes

  The index process holds state and coordinates two linked workers, each
  owning one connection. The reader serves queries and the writer runs loads
  and imports one at a time. In a file-backed index, WAL mode lets reads see
  the last committed state while a write runs. An in-memory index shares one
  `memdb` database between the two connections, so a read issued during a
  write may wait for the commit, but never sees a mixture.

  The database is derived data. One whose storage schema version this code
  doesn't know is recreated empty, emitting `[:tama_dex, :index, :recreated]`,
  and the host loads its documents again.
  """

  use GenServer

  alias Tama.Dex.Index.Connection
  alias Tama.Dex.Index.Worker
  alias Tama.Dex.Profile

  @type t :: GenServer.server()

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts an index. See the module documentation for the options.

  Raises `ArgumentError`, creating nothing, when `:path` is missing or an
  option is invalid.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    location = location!(Keyword.get(opts, :path))
    limits = Profile.limits!(Keyword.get(opts, :limits, []))

    gen_opts =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> [name: name]
        :error -> []
      end

    GenServer.start_link(__MODULE__, %{location: location, limits: limits}, gen_opts)
  end

  defp location!(:memory) do
    "file:/tama-dex-#{System.unique_integer([:positive])}-#{:erlang.unique_integer([:positive])}?vfs=memdb"
  end

  defp location!(path) when is_binary(path) and path != "", do: Path.expand(path)

  defp location!(nil),
    do: raise(ArgumentError, "Tama.Dex.Index needs a :path, a file path or :memory")

  defp location!(path) do
    raise ArgumentError,
          "Tama.Dex.Index :path must be a file path or :memory, got: #{inspect(path)}"
  end

  @doc false
  # The limits documents loaded into this index are validated under.
  @spec limits(t()) :: keyword()
  def limits(index), do: GenServer.call(index, :limits)

  @doc false
  # Runs `job.(conn)` on the read connection and returns its result.
  @spec read(t(), (term() -> result)) :: result when result: term()
  def read(index, job) do
    index |> GenServer.call({:read, job}, :infinity) |> unwrap()
  end

  @doc false
  # Runs `job.(conn)` on the write connection. The job returns
  # `{:changed, reply}` after committing a change, or `{:unchanged, reply}`.
  @spec write(t(), (term() -> {:changed | :unchanged, result})) :: result when result: term()
  def write(index, job) do
    index |> GenServer.call({:write, job}, :infinity) |> unwrap()
  end

  @doc false
  # The public ETS table of compiled schemas, keyed by schema digest.
  @spec schema_cache(t()) :: :ets.tid()
  def schema_cache(index), do: GenServer.call(index, :schema_cache)

  @doc false
  # The compiled form of a stored schema, compiled on first use and cached
  # under its digest. Opening an index compiles nothing.
  @spec compiled_schema(:ets.tid(), String.t(), String.t()) ::
          {:ok, JSONSchex.Types.Schema.t()} | {:error, JSONSchex.Types.Error.t()}
  def compiled_schema(cache, digest, text) do
    case :ets.lookup(cache, digest) do
      [{^digest, compiled}] ->
        {:ok, compiled}

      [] ->
        with {:ok, compiled} <- JSONSchex.compile(Jason.decode!(text), draft: "draft2020_12") do
          :ets.insert(cache, {digest, compiled})
          {:ok, compiled}
        end
    end
  end

  defp unwrap({:ok, {_changed, reply}}), do: reply
  defp unwrap({:ok, reply}), do: reply
  defp unwrap({:raise, exception, stacktrace}), do: reraise(exception, stacktrace)
  defp unwrap({kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  @impl GenServer
  def init(%{location: location, limits: limits}) do
    with {:ok, writer} <- Worker.start_link({:writer, location}),
         {:ok, reader} <- Worker.start_link({:reader, location}) do
      emit_schema_event(GenServer.call(writer, :schema))
      cache = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
      {:ok, %{reader: reader, writer: writer, limits: limits, cache: cache}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:limits, _from, state), do: {:reply, state.limits, state}
  def handle_call(:schema_cache, _from, state), do: {:reply, state.cache, state}

  def handle_call({:read, job}, from, state) do
    send(state.reader, {:read, from, job})
    {:noreply, state}
  end

  def handle_call({:write, job}, from, state) do
    send(state.writer, {:write, from, job, self()})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:written, from, result, referenced}, state) do
    sweep(state.cache, referenced)
    GenServer.reply(from, result)
    {:noreply, state}
  end

  defp sweep(_cache, :unchanged), do: :ok

  defp sweep(cache, {:ok, digests}) do
    for digest <- :ets.select(cache, [{{:"$1", :_}, [], [:"$1"]}]),
        not MapSet.member?(digests, digest) do
      :ets.delete(cache, digest)
    end

    :ok
  end

  defp emit_schema_event(:current), do: :ok

  defp emit_schema_event({:recreated, old}) do
    :telemetry.execute([:tama_dex, :index, :recreated], %{}, %{
      old_version: old,
      version: Connection.schema_version()
    })
  end
end
