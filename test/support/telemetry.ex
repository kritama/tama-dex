defmodule Tama.Dex.TestSupport.Telemetry do
  @moduledoc false

  # Like :telemetry_test.attach_event_handlers/2, but forwards only events
  # emitted by the calling process, so concurrent tests' events never mix
  # in. For spans that run in the caller: load, search and execute.

  @doc "Attaches to `events` and returns the ref the forwarded messages carry."
  def attach_local(events) do
    ref = make_ref()
    :ok = :telemetry.attach_many(ref, events, &__MODULE__.forward/4, {self(), ref})
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  @doc false
  def forward(event, measurements, metadata, {test, ref}) do
    if self() == test, do: send(test, {event, ref, measurements, metadata})
  end
end
