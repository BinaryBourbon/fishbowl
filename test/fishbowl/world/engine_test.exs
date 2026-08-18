defmodule Fishbowl.World.EngineTest do
  use ExUnit.Case, async: true

  alias Fishbowl.World.Engine

  test "release/4 drops a herbivore or predator on a passable tile" do
    state = Engine.new(5, 5)

    state = Engine.release(state, :herbivore, 1, 1)

    assert Enum.any?(state.entities, fn {_id, e} ->
             e.kind == :herbivore and e.x == 1 and e.y == 1
           end)

    state = Engine.release(state, :predator, 2, 2)

    assert Enum.any?(state.entities, fn {_id, e} ->
             e.kind == :predator and e.x == 2 and e.y == 2
           end)
  end

  test "freshly released or planted entities start with action :spawned" do
    state = Engine.new(5, 5) |> Engine.release(:predator, 1, 1) |> Engine.plant_seed(2, 2, "p1")

    assert Enum.all?(state.entities, fn {_id, e} -> e.action == :spawned end)
  end

  test "a predator with no reachable prey and no room to move goes idle" do
    # A single free tile boxed in by rock on all sides: nothing to eat,
    # nowhere to step. (Immigration could still drop an unrelated entity on
    # this tile in the same tick, so track this predator by id rather than
    # assuming it's the only entity left afterward.)
    state = Engine.new(3, 3)

    state =
      for x <- 0..2, y <- 0..2, {x, y} != {1, 1}, reduce: state do
        acc -> Engine.place_rock(acc, x, y)
      end

    state = Engine.release(state, :predator, 1, 1)
    [predator_id] = Map.keys(state.entities)

    state = Engine.tick(state)
    predator = Map.fetch!(state.entities, predator_id)

    assert predator.action == :idle
    assert {predator.x, predator.y} == {1, 1}
  end

  test "a herbivore standing on its target plant eats it" do
    state = Engine.new(3, 3) |> Engine.plant_seed(1, 1, "p1") |> Engine.release(:herbivore, 1, 1)
    herbivore_id = state.entities |> Enum.find_value(fn {id, e} -> e.kind == :herbivore && id end)

    state = Engine.tick(state)

    assert Map.fetch!(state.entities, herbivore_id).action == :ate
  end

  test "release/4 is a no-op on a rock tile" do
    state = Engine.new(5, 5) |> Engine.place_rock(1, 1)

    state = Engine.release(state, :herbivore, 1, 1)
    refute Enum.any?(state.entities, fn {_id, e} -> e.x == 1 and e.y == 1 end)
  end

  test "tick/1 eventually immigrates herbivores and predators back from zero" do
    # Assert "immigration introduces each species at some point," not "the
    # population survives to this exact tick" — a freshly-immigrated
    # herbivore can get hunted down by an already-present predator within a
    # tick or two, so sampling only the final tick is exposed to real
    # predation dynamics, not just immigration odds, and flakes under that
    # combination more often than the per-tick chance alone suggests.
    state = Engine.new(20, 20)
    seen = %{herbivore: false, predator: false, plant: false}

    {_state, seen} =
      Enum.reduce(1..150, {state, seen}, fn _, {acc, seen} ->
        acc = Engine.tick(acc)
        counts = acc.entities |> Map.values() |> Enum.map(& &1.kind) |> Enum.frequencies()

        seen = %{
          herbivore: seen.herbivore or Map.get(counts, :herbivore, 0) > 0,
          predator: seen.predator or Map.get(counts, :predator, 0) > 0,
          plant: seen.plant or Map.get(counts, :plant, 0) > 0
        }

        {acc, seen}
      end)

    assert seen.herbivore
    assert seen.predator
    assert seen.plant
  end

  test "tick/1 tolerates state persisted before the weather field existed" do
    # No :weather key at all — as a snapshot saved before this field
    # existed would look. tick_weather only ever adds the key back once
    # rain actually starts, so the real assertion is just that repeated
    # ticks don't raise on the missing key.
    state = Engine.new(5, 5) |> Map.delete(:weather)

    state = Enum.reduce(1..5, state, fn _, acc -> Engine.tick(acc) end)

    assert state.tick == 5
    assert Engine.weather(state) == nil or is_map(Engine.weather(state))
  end

  test "rain eventually waters some tiles" do
    state = Engine.new(20, 20)
    state = Enum.reduce(1..300, state, fn _, acc -> Engine.tick(acc) end)

    assert Enum.any?(state.tiles, fn {_pos, tile} -> tile.fertility > 0.5 end)
  end

  test "tick/1 tolerates a weather value from before rain was a random blob" do
    # The very first rain shipped as a plain rectangle (x/y/w/h). A
    # snapshot saved mid-storm at that point wouldn't have :tiles at all —
    # Engine.weather/1 should treat that as "not raining" rather than
    # crash the first time tick_weather touches it.
    old_shaped = %{x: 2, y: 2, w: 3, h: 3, ticks_left: 2}
    state = Engine.new(10, 10) |> Map.put(:weather, old_shaped)

    assert Engine.weather(state) == nil
    state = Engine.tick(state)
    assert state.tick == 1
  end

  test "a rain patch is a single connected blob, grown by random walk" do
    state = Engine.new(30, 30)

    patch =
      Enum.reduce_while(1..300, state, fn _, acc ->
        acc = Engine.tick(acc)

        case Engine.weather(acc) do
          nil -> {:cont, acc}
          weather -> {:halt, weather}
        end
      end)

    assert %{tiles: tiles} = patch
    assert MapSet.size(tiles) in 10..20
    assert connected?(tiles)
  end

  defp connected?(tiles) do
    [start | _] = MapSet.to_list(tiles)
    reached = flood_fill(MapSet.new([start]), [start], tiles)
    MapSet.size(reached) == MapSet.size(tiles)
  end

  defp flood_fill(reached, [], _tiles), do: reached

  defp flood_fill(reached, [{x, y} | rest], tiles) do
    neighbors =
      for dx <- -1..1, dy <- -1..1, {dx, dy} != {0, 0}, do: {x + dx, y + dy}

    new =
      neighbors
      |> Enum.filter(&(MapSet.member?(tiles, &1) and not MapSet.member?(reached, &1)))

    flood_fill(MapSet.union(reached, MapSet.new(new)), new ++ rest, tiles)
  end
end
