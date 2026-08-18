defmodule Fishbowl.World.SnapshotTest do
  use ExUnit.Case, async: false

  alias Fishbowl.World.{Engine, Entity, Snapshot, Tile}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "fishbowl_snapshot_test_#{System.unique_integer([:positive])}.bin"
      )

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

  test "load/0 backfills Entity fields added after the snapshot was written", %{path: path} do
    state = Engine.new(5, 5) |> Engine.plant_seed(1, 1, "alice")
    [{id, entity}] = Map.to_list(state.entities)

    # Simulate a snapshot from an older build whose Entity had no :action key.
    old_entity =
      entity |> Map.from_struct() |> Map.delete(:action) |> Map.put(:__struct__, Entity)

    File.write!(path, :erlang.term_to_binary(%{state | entities: %{id => old_entity}}))

    assert {:ok, loaded} = Snapshot.load()
    assert %Entity{action: :spawned} = loaded.entities[id]

    # And the migrated world must actually tick.
    assert %{tick: 1} = Engine.tick(loaded)
  end

  test "load/0 backfills Tile fields added after the snapshot was written", %{path: path} do
    state = Engine.new(5, 5)

    # Simulate a snapshot from before Tile had a :fertilized key.
    old_tile =
      %Tile{} |> Map.from_struct() |> Map.delete(:fertilized) |> Map.put(:__struct__, Tile)

    File.write!(path, :erlang.term_to_binary(%{state | tiles: %{{0, 0} => old_tile}}))

    assert {:ok, loaded} = Snapshot.load()
    assert %Tile{fertilized: false} = loaded.tiles[{0, 0}]

    # And the migrated world must actually tick.
    assert %{tick: 1} = Engine.tick(loaded)
  end

  test "load/0 returns :error when no snapshot exists yet" do
    assert Snapshot.load() == :error
  end
end
