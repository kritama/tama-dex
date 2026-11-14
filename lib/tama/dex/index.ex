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

  ## Readiness

  `status/1` reports whether the index can serve. Search must never block or
  fail a host's startup, so while nothing is committed and a load or import
  runs, `Tama.Dex.search/3` and `Tama.Dex.describe/4` return
  `{:error, :not_ready}` and `Tama.Dex.execute/5` a `:not_ready` error,
  without waiting. See `status/1`.
  """

  use GenServer

  alias Tama.Dex.Index.Connection
  alias Tama.Dex.Index.Job
  alias Tama.Dex.Index.Worker
  alias Tama.Dex.Profile

  @type t :: GenServer.server()

  @type progress :: %{cassette: String.t(), done: non_neg_integer(), total: non_neg_integer()}

  @type status :: :ready | {:importing, progress()} | {:failed, atom()} | :empty

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

  @doc """
  The index's readiness as a whole:

  - `:ready` whenever at least one cassette is committed, even while other
    loads or imports run or after one has failed;
  - otherwise `{:importing, %{cassette, done, total}}` while a load or
    import runs or waits, counting sources;
  - otherwise `{:failed, reason}` when the last attempt failed, with the
    kind of its error, such as `:deadline`;
  - otherwise `:empty`.

  `:ready` means at least one cassette is committed, not all of them. Each
  cassette's own status is in `Tama.Dex.cassettes/1`. Every change emits
  `[:tama_dex, :index, :status]` with the new `status` and the `index` pid
  in its metadata.

  Reads the index's state only, so it never waits on SQLite.
  """
  @spec status(t()) :: status()
  def status(index), do: GenServer.call(index, :status)

  @doc false
  # Runs `job.(conn)` on the read connection and returns its result.
  @spec read(t(), (term() -> result)) :: result when result: term()
  def read(index, job) do
    index |> GenServer.call({:read, job, nil}, :infinity) |> unwrap()
  end

  @doc false
  # Like `read/2`, but returns `{:error, :not_ready}` without reading when
  # the index isn't ready (`:index`), or isn't ready for one cassette
  # (`{:cassette, name}`: the index isn't ready, or the cassette's first
  # load or import is still running).
  @spec read_ready(t(), :index | {:cassette, String.t()}, (term() -> result)) ::
          {:ok, result} | {:error, :not_ready}
        when result: term()
  def read_ready(index, scope, job) do
    case GenServer.call(index, {:read, job, scope}, :infinity) do
      :not_ready -> {:error, :not_ready}
      reply -> {:ok, unwrap(reply)}
    end
  end

  @doc false
  # The cassettes with a load or import running or waiting, or whose last
  # attempt failed, and no committed entries: `%{name => %{kind, status}}`.
  @spec pending(t()) :: %{String.t() => %{kind: :local | :imported, status: term()}}
  def pending(index), do: GenServer.call(index, :pending)

  @doc false
  # Runs a tracked load or import of one cassette: `job.(conn, job_context)`
  # on the write connection, returning `{:changed, reply}` or
  # `{:unchanged, reply}`. Options: `:cassette` and `:kind` (required),
  # `:deadline` (a monotonic millisecond deadline, or nil).
  @spec run(t(), (term(), Job.t() -> {:changed | :unchanged, result}), keyword()) :: result
        when result: term()
  def run(index, job, opts) do
    index |> GenServer.call({:run, job, opts, :call}, :infinity) |> unwrap()
  end

  @doc false
  # Like `run/3`, but returns at once. The calling process later receives
  # `{:tama_dex_import, ref, reply}`.
  @spec run_async(
          t(),
          (term(), Job.t() -> {:changed | :unchanged, term()}),
          keyword(),
          reference()
        ) ::
          :ok
  def run_async(index, job, opts, ref) do
    GenServer.call(index, {:run, job, opts, {:async, self(), ref}}, :infinity)
  end

  @doc false
  # Runs `job.(conn)` on the write connection. The job returns
  # `{:changed, reply}` after committing a change, or `{:unchanged, reply}`.
  # `forget: cassette` drops that cassette's failed-attempt status.
  @spec write(t(), (term() -> {:changed | :unchanged, result}), keyword()) :: result
        when result: term()
  def write(index, job, opts \\ []) do
    index |> GenServer.call({:write, job, opts}, :infinity) |> unwrap()
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

      state = %{
        reader: reader,
        writer: writer,
        limits: limits,
        cache: cache,
        # Readiness: committed cassette names, tracked writes by cassette,
        # failed attempts of uncommitted cassettes, and the last outcome.
        committed: MapSet.new(GenServer.call(writer, :cassette_names)),
        tracking: %{},
        failures: %{},
        last: :ok,
        sequence: 0
      }

      {:ok, Map.put(state, :status, compute_status(state))}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:limits, _from, state), do: {:reply, state.limits, state}
  def handle_call(:schema_cache, _from, state), do: {:reply, state.cache, state}
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:pending, _from, state) do
    importing =
      for {cassette, entry} <- state.tracking,
          not MapSet.member?(state.committed, cassette),
          into: %{} do
        {cassette, %{kind: entry.kind, status: {:importing, progress(cassette, entry)}}}
      end

    failed =
      for {cassette, {kind, reason}} <- state.failures,
          not Map.has_key?(importing, cassette),
          into: %{} do
        {cassette, %{kind: kind, status: {:failed, reason}}}
      end

    {:reply, Map.merge(failed, importing), state}
  end

  def handle_call({:read, job, scope}, from, state) do
    if ready?(state, scope) do
      send(state.reader, {:read, from, job})
      {:noreply, state}
    else
      {:reply, :not_ready, state}
    end
  end

  def handle_call({:write, job, opts}, from, state) do
    state =
      case Keyword.get(opts, :forget) do
        nil -> state
        cassette -> update_status(%{state | failures: Map.delete(state.failures, cassette)})
      end

    send(state.writer, {:write, from, job, self(), nil})
    {:noreply, state}
  end

  def handle_call({:run, job, opts, reply}, from, state) do
    cassette = Keyword.fetch!(opts, :cassette)
    tracked = %Job{cassette: cassette, deadline: Keyword.get(opts, :deadline)}

    target =
      case reply do
        :call -> from
        {:async, pid, ref} -> {:async, pid, ref}
      end

    send(state.writer, {:write, target, job, self(), tracked})
    state = track(state, cassette, Keyword.fetch!(opts, :kind))

    case reply do
      :call -> {:noreply, state}
      {:async, _pid, _ref} -> {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_info({:progress, cassette, done, total}, state) do
    state =
      case state.tracking do
        %{^cassette => entry} ->
          tracking = Map.put(state.tracking, cassette, %{entry | done: done, total: total})
          update_status(%{state | tracking: tracking})

        _other ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:written, from, result, referenced, tracked}, state) do
    sweep(state.cache, referenced)

    state =
      state
      |> commit(referenced)
      |> settle(tracked, result)
      |> update_status()

    reply(from, result)
    {:noreply, state}
  end

  defp reply({:async, pid, ref}, result),
    do: send(pid, {:tama_dex_import, ref, async_reply(result)})

  defp reply(from, result), do: GenServer.reply(from, result)

  # A background import has no caller to re-raise in, so a crashed job is
  # reported as an error.
  defp async_reply({:ok, {_changed, reply}}), do: reply
  defp async_reply({:ok, reply}), do: reply
  defp async_reply(_crashed), do: {:error, :exception}

  # Readiness

  defp ready?(_state, nil), do: true

  defp ready?(state, :index) do
    MapSet.size(state.committed) > 0 or map_size(state.tracking) == 0
  end

  defp ready?(state, {:cassette, cassette}) do
    ready?(state, :index) and
      (MapSet.member?(state.committed, cassette) or not Map.has_key?(state.tracking, cassette))
  end

  defp track(state, cassette, kind) do
    entry =
      Map.get(state.tracking, cassette, %{
        kind: kind,
        count: 0,
        done: 0,
        total: 0,
        sequence: state.sequence
      })

    tracking = Map.put(state.tracking, cassette, %{entry | count: entry.count + 1})
    update_status(%{state | tracking: tracking, sequence: state.sequence + 1})
  end

  defp commit(state, {:ok, _digests, names}), do: %{state | committed: MapSet.new(names)}
  defp commit(state, :unchanged), do: state

  defp settle(state, nil, _result), do: state

  defp settle(state, %Job{cassette: cassette}, result) do
    {kind, tracking} =
      case Map.fetch!(state.tracking, cassette) do
        %{count: 1} = entry ->
          {entry.kind, Map.delete(state.tracking, cassette)}

        entry ->
          {entry.kind, Map.put(state.tracking, cassette, %{entry | count: entry.count - 1})}
      end

    state = %{state | tracking: tracking}

    case outcome(result) do
      :ok ->
        %{state | failures: Map.delete(state.failures, cassette), last: :ok}

      {:failed, reason} ->
        failures =
          if MapSet.member?(state.committed, cassette),
            do: Map.delete(state.failures, cassette),
            else: Map.put(state.failures, cassette, {kind, reason})

        %{state | failures: failures, last: {:failed, reason}}
    end
  end

  defp outcome({:ok, {_changed, {:error, reason}}}), do: {:failed, error_kind(reason)}
  defp outcome({:ok, {_changed, _reply}}), do: :ok
  defp outcome(_crashed), do: {:failed, :exception}

  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp error_kind(_reason), do: :error

  defp update_status(state) do
    case compute_status(state) do
      status when status == state.status ->
        state

      status ->
        :telemetry.execute([:tama_dex, :index, :status], %{}, %{status: status, index: self()})
        %{state | status: status}
    end
  end

  defp compute_status(state) do
    cond do
      MapSet.size(state.committed) > 0 ->
        :ready

      map_size(state.tracking) > 0 ->
        {cassette, entry} =
          Enum.min_by(state.tracking, fn {_cassette, entry} -> entry.sequence end)

        {:importing, progress(cassette, entry)}

      match?({:failed, _reason}, state.last) ->
        state.last

      true ->
        :empty
    end
  end

  defp progress(cassette, entry), do: %{cassette: cassette, done: entry.done, total: entry.total}

  defp sweep(_cache, :unchanged), do: :ok

  defp sweep(cache, {:ok, digests, _names}) do
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
