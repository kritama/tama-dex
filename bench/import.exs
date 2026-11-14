# Measures how long indexing takes, against the 2 s target for rebuilding a
# 1024-operation document set (design Decision 10). Release evidence, not a
# test: run it with
#
#     mix run bench/import.exs
#
# Each case runs in a fresh file-backed index in a temporary directory, which
# is removed afterwards. Prints the median and slowest of several runs, in
# milliseconds, as a Markdown table.

defmodule Tama.Dex.Bench do
  @runs 5
  @target_ms 2_000
  @fixture Path.expand("../test/fixtures/profile/valid/opsmaru_incus.json", __DIR__)

  def run do
    dir = Path.join(System.tmp_dir!(), "tama-dex-bench-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      incus = @fixture |> File.read!() |> Jason.decode!()

      rows =
        [{"1024 operations", [generated(incus, 1024)]}, {"opsmaru_incus fixture", [incus]}]
        |> Enum.flat_map(&measure(&1, dir))

      print(rows)
    after
      File.rm_rf!(dir)
    end
  end

  # One document of `count` operations, cycling through the fixture's
  # operations under new IDs, so each keeps realistic schemas, scopes and
  # confirmation rules.
  defp generated(incus, count) do
    operations = Enum.map(incus["paths"], fn {_path, item} -> item["post"] end)

    paths =
      operations
      |> Stream.cycle()
      |> Enum.take(count)
      |> Enum.with_index(1)
      |> Map.new(fn {operation, n} ->
        id = "#{operation["operationId"]}_#{String.pad_leading(Integer.to_string(n), 4, "0")}"
        {"/operations/#{id}", %{"post" => Map.put(operation, "operationId", id)}}
      end)

    Map.merge(incus, %{"x-tama-source" => "bench", "paths" => paths})
  end

  defp measure({label, documents}, dir) do
    operations = Enum.sum_by(documents, &map_size(&1["paths"]))
    path = Path.join(dir, "bench.tama-cassette")

    {build_ms, {:ok, built}} =
      timed(fn -> Tama.Dex.Cassette.build(documents, path, name: "bench", version: "1") end)

    [
      {label, operations, "load (rebuild)", runs(dir, &load(&1, documents))},
      {label, operations, "import, unpinned (rebuild)", runs(dir, &import(&1, path, nil))},
      {label, operations, "import, pinned (copy)", runs(dir, &import(&1, path, built.sha256))},
      {label, operations, "cassette build", [build_ms]}
    ]
  end

  defp load(index, documents) do
    Enum.each(documents, fn document ->
      {:ok, %{changed: true}} = Tama.Dex.load(index, document, cassette: "bench")
    end)
  end

  defp import(index, path, pin) do
    {:ok, %{changed: true}} = Tama.Dex.import(index, path, sha256: pin)
  end

  defp runs(dir, fun) do
    for run <- 1..@runs do
      database = Path.join(dir, "index-#{run}.sqlite3")
      {:ok, index} = Tama.Dex.Index.start_link(path: database)

      try do
        {ms, _result} = timed(fn -> fun.(index) end)
        ms
      after
        GenServer.stop(index)
        Enum.each(Path.wildcard(database <> "*"), &File.rm!/1)
      end
    end
  end

  defp timed(fun) do
    {microseconds, result} = :timer.tc(fun)
    {microseconds / 1000, result}
  end

  defp print(rows) do
    IO.puts("""
    tama-dex #{Application.spec(:tama_dex, :vsn)}, Elixir #{System.version()}, \
    OTP #{System.otp_release()}, #{:erlang.system_info(:system_architecture)}, \
    #{System.schedulers_online()} schedulers. Median and slowest of #{@runs} runs, in ms.

    | Documents | Operations | Case | Median | Slowest |
    | --- | ---: | --- | ---: | ---: |\
    """)

    for {label, operations, name, times} <- rows do
      IO.puts(
        "| #{label} | #{operations} | #{name} | #{ms(median(times))} | #{ms(Enum.max(times))} |"
      )
    end

    slow =
      for {label, 1024, name, times} <- rows,
          name != "cassette build" and median(times) > @target_ms,
          do: "#{label} #{name}"

    if slow != [] do
      IO.puts("\n::warning::Over the #{@target_ms} ms target: #{Enum.join(slow, ", ")}")
    end
  end

  defp median(times), do: times |> Enum.sort() |> Enum.at(div(length(times), 2))
  defp ms(value), do: :erlang.float_to_binary(value / 1, decimals: 1)
end

Tama.Dex.Bench.run()
