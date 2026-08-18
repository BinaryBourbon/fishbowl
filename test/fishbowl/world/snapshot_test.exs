defmodule Fishbowl.World.SnapshotTest do
  use ExUnit.Case, async: false

  alias Fishbowl.World.{Engine, Snapshot}

  setup do
    path = Path.join(System.tmp_dir!(), "fishbowl_snapshot_test_#{System.unique_integer([:positive])}.bin")
    Application.put_env(:fishbowl, :snapshot_path, path)

    on_exit(fn ->
      File.rm(path)
      Application.delete_env(:fishbowl, :snapshot_path)
    end)

    {:ok, path: path}
  end

  test "round-trips full world state through disk" do
    state =
      Engine.new(5, 5)
      |> Engine.plant_seed(1, 1, "alice")
      |> Engine.place_rock(2, 2)
      |> Engine.water(3, 3)

    assert :ok = Snapshot.save(state)
    assert {:ok, loaded} = Snapshot.load()
    assert loaded == state
  end

  test "load/0 returns :error when no snapshot exists yet" do
    assert Snapshot.load() == :error
  end
end
