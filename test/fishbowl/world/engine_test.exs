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
    state = Engine.new(20, 20)

    # Unseeded: entity ids come from :crypto.strong_rand_bytes, which
    # :rand.seed can't pin, so map-iteration order (and thus which entity
    # consumes which :rand draw) still varies run to run even with a fixed
    # seed. 150 ticks at a 15% per-tick immigration chance leaves failure
    # probability negligible without fighting that.
    state = Enum.reduce(1..150, state, fn _, acc -> Engine.tick(acc) end)

    counts = state.entities |> Map.values() |> Enum.map(& &1.kind) |> Enum.frequencies()
    assert Map.get(counts, :herbivore, 0) > 0
    assert Map.get(counts, :predator, 0) > 0
    assert Map.get(counts, :plant, 0) > 0
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
end
