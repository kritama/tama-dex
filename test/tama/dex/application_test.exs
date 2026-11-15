defmodule Tama.Dex.ApplicationTest do
  # Stops and restarts the :tama_dex application, so it must not run
  # alongside other tests.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  test "has no application callback" do
    assert Application.spec(:tama_dex, :mod) == []
  end

  test "starting the application creates no process, ETS table or file", %{tmp_dir: tmp_dir} do
    :ok = Application.stop(:tama_dex)

    processes_before = MapSet.new(Process.list())
    tables_before = MapSet.new(:ets.all())

    File.cd!(tmp_dir, fn ->
      assert {:ok, _started} = Application.ensure_all_started(:tama_dex)
    end)

    new_processes = MapSet.difference(MapSet.new(Process.list()), processes_before)
    new_tables = MapSet.difference(MapSet.new(:ets.all()), tables_before)

    assert Enum.filter(new_processes, &owned_by_tama_dex?/1) == []
    assert Enum.filter(Process.list(), &owned_by_tama_dex?/1) == []
    assert MapSet.size(new_tables) == 0
    assert File.ls!(tmp_dir) == []
  end

  defp owned_by_tama_dex?(pid), do: :application.get_application(pid) == {:ok, :tama_dex}
end
