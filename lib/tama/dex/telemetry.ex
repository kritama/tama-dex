defmodule Tama.Dex.Telemetry do
  @moduledoc """
  The telemetry events tama-dex emits.

  Metadata is bounded and free of secrets. It never holds query text (only
  its length), `execute` inputs or results, schemas, documents or file
  paths.

  ## Spans

  `[:tama_dex, name, :start | :stop | :exception]`, where `name` is
  `:load`, `:import`, `:search` or `:execute`. `:start` carries
  `monotonic_time` and `system_time`, `:stop` and `:exception` carry
  `duration` and `monotonic_time`, in native time units. All three carry a
  `telemetry_span_context` that ties them together.

  | Span | `:start` metadata | `:stop` adds |
  | --- | --- | --- |
  | `:load` | `cassette` | `result` (`:ok` or the error kind), and on success `source`, `operations`, `changed` |
  | `:import` | `cassette` | `result`, and on success `version`, `mode`, `changed`, `sources`, `operations` |
  | `:search` | `cassette` (or nil), `query_length` (bytes), `limit` | `results`, `truncated`, and `not_ready: true` when the index wasn't ready |
  | `:execute` | `cassette`, `operation_id` | `source` (or nil), `outcome` (`:ok`, `:operation_error` or a `Tama.Dex.Error` kind) |

  `:load`, `:search` and `:execute` run in the calling process. `:import`
  runs in the index's writer process.

  An `:exception` event has the `:start` metadata plus `kind`, `reason` and
  `stacktrace`, reduced so they hold no data:

  - `reason` is the exception's module for an error (an Erlang error is
    normalized first, so `:function_clause` gives `FunctionClauseError`),
    an atom reason as is,
    the first element of a tuple reason when it's an atom (such as
    `:noproc` from an exit), and otherwise `:unknown`;
  - `stacktrace` entries keep their module, function, arity and location,
    with argument lists replaced by their arity.

  The exception itself still reaches the caller unchanged.

  ## Index events

  - `[:tama_dex, :index, :recreated]`: a database with an unknown schema
    version was recreated empty. Metadata: `old_version`, `version`.
  - `[:tama_dex, :index, :status]`: `Tama.Dex.Index.status/1` changed.
    Metadata: `status`, and `index`, the index's pid.
  """

  @doc false
  @spec span([atom()], map(), (-> {result, map()})) :: result when result: term()
  def span(event, metadata, fun) do
    start = System.monotonic_time()
    metadata = Map.put(metadata, :telemetry_span_context, make_ref())

    :telemetry.execute(
      event ++ [:start],
      %{monotonic_time: start, system_time: System.system_time()},
      metadata
    )

    try do
      fun.()
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        stop = System.monotonic_time()

        :telemetry.execute(
          event ++ [:exception],
          %{duration: stop - start, monotonic_time: stop},
          Map.merge(metadata, %{
            kind: kind,
            reason: reason(kind, reason, stacktrace),
            stacktrace: Enum.map(stacktrace, &frame/1)
          })
        )

        :erlang.raise(kind, reason, stacktrace)
    else
      {result, stop_metadata} ->
        stop = System.monotonic_time()

        :telemetry.execute(
          event ++ [:stop],
          %{duration: stop - start, monotonic_time: stop},
          Map.put(stop_metadata, :telemetry_span_context, metadata.telemetry_span_context)
        )

        result
    end
  end

  defp reason(:error, reason, stacktrace),
    do: Exception.normalize(:error, reason, stacktrace).__struct__

  defp reason(_kind, reason, _stacktrace) when is_atom(reason), do: reason

  defp reason(_kind, reason, _stacktrace) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp reason(_kind, _reason, _stacktrace), do: :unknown

  defp frame({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp frame({module, function, arity, location}), do: {module, function, arity, location}
  defp frame(_frame), do: :unknown
end
