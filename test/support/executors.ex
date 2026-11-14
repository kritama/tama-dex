defmodule Tama.Dex.TestSupport.CountingExecutor do
  @moduledoc false

  # Reports every call to the test process given in `opts[:test]`, then
  # answers with `opts[:respond].(call, input)`, or `{:ok, %{}}`.

  @behaviour Tama.Dex.Executor

  @impl Tama.Dex.Executor
  def execute(call, input) do
    send(Keyword.fetch!(call.opts, :test), {:executed, call, input})

    case Keyword.fetch(call.opts, :respond) do
      {:ok, respond} -> respond.(call, input)
      :error -> {:ok, %{}}
    end
  end
end

defmodule Tama.Dex.TestSupport.NoCallbackExecutor do
  @moduledoc false

  def run(_call, _input), do: {:ok, %{}}
end
