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

  test "events/1 logs an extinction when a thriving species drops to zero" do
    # Immigration runs right after death in the same tick and could refill
    # the population (~15% chance) before track_events compares pre/post
    # counts, masking a real extinction as "stayed at 1." Rather than fight
    # that structurally — any free tile anywhere satisfies immigration, so
    # there's no cheap way to guarantee it fails — repeat the scenario a
    # few times; failure requires the same ~15% coincidence every time.
    result =
      Enum.find(1..5, fn _ ->
        state = Engine.new(5, 5) |> Engine.release(:predator, 1, 1)
        [id] = Map.keys(state.entities)
        state = %{state | entities: %{id => %{state.entities[id] | energy: 0.01}}}
        state = Engine.tick(state)
        Enum.any?(Engine.events(state), &(&1.text =~ "predators went extinct"))
      end)

    assert result
  end

  test "events/1 logs a population record once a species crosses its threshold" do
    state = Engine.new(10, 10)
    state = Enum.reduce(1..6, state, fn i, acc -> Engine.release(acc, :predator, i, 0) end)

    # First tick just establishes the baseline (6) — the initial seed
    # population isn't itself a "record," see the record > 0 guard.
    state = Engine.tick(state)
    refute Enum.any?(Engine.events(state), &(&1.text =~ "population record"))

    # Far from the original row: predators wander at most one tile per
    # tick, so nothing from the (1,0)-(6,0) group could already be sitting
    # here and blocking the release under the same-kind exclusivity rule.
    state = state |> Engine.release(:predator, 9, 9) |> Engine.tick()

    assert Enum.any?(Engine.events(state), &(&1.text =~ "population record: 7"))
  end

  test "events/1 does not log a record below the species' threshold" do
    state = Engine.new(10, 10) |> Engine.release(:predator, 1, 1)
    state = Engine.tick(state)

    refute Enum.any?(Engine.events(state), &(&1.text =~ "population record"))
  end

  test "events/1 logs when rain starts" do
    state = Engine.new(20, 20)

    state =
      Enum.reduce_while(1..300, state, fn _, acc ->
        acc = Engine.tick(acc)
        if Engine.weather(acc), do: {:halt, acc}, else: {:cont, acc}
      end)

    assert Enum.any?(Engine.events(state), &(&1.text == "a storm rolled in"))
  end

  test "events/1 is capped and newest-first" do
    state = Engine.new(15, 15)

    state =
      Enum.reduce(1..40, state, fn i, acc ->
        acc
        |> Engine.release(:predator, rem(i, 15), div(i, 15))
        |> Engine.tick()
      end)

    events = Engine.events(state)
    assert length(events) <= 30
    ticks = Enum.map(events, & &1.tick)
    assert ticks == Enum.sort(ticks, :desc)
  end

  test "tick/1 tolerates state persisted before events/records existed" do
    state = Engine.new(5, 5) |> Map.delete(:events) |> Map.delete(:records)
    state = Engine.tick(state)

    # Not asserting events == [] — rain has its own small per-tick chance
    # and can legitimately log "a storm rolled in" here. The real thing
    # under test is that missing :events/:records don't raise.
    assert is_list(Engine.events(state))
  end

  test "daylight/1 oscillates smoothly between 0.0 and 1.0" do
    state = Engine.new(5, 5)

    samples =
      Enum.map(0..199, fn tick ->
        Engine.daylight(%{state | tick: tick})
      end)

    assert Enum.all?(samples, &(&1 >= 0.0 and &1 <= 1.0))
    assert Enum.max(samples) > 0.99
    assert Enum.min(samples) < 0.01
  end

  test "day?/1 is true at noon-equivalent tick and false at midnight-equivalent tick" do
    state = Engine.new(5, 5)
    assert Engine.day?(%{state | tick: 0})
    refute Engine.day?(%{state | tick: 100})
  end

  test "plants grow faster in daylight than at night" do
    day = Engine.new(5, 5) |> Map.put(:tick, 0) |> Engine.plant_seed(1, 1, "p1")
    night = Engine.new(5, 5) |> Map.put(:tick, 100) |> Engine.plant_seed(1, 1, "p1")

    day_energy = day |> Engine.tick() |> plant_energy_at(1, 1)
    night_energy = night |> Engine.tick() |> plant_energy_at(1, 1)

    assert day_energy > night_energy
  end

  test "add_fertilizer/3 makes a plant on that tile grow faster than an unfertilized one" do
    plain = Engine.new(5, 5) |> Engine.plant_seed(1, 1, "p1")
    fertilized = Engine.new(5, 5) |> Engine.add_fertilizer(1, 1) |> Engine.plant_seed(1, 1, "p1")

    plain_energy = plain |> Engine.tick() |> plant_energy_at(1, 1)
    fertilized_energy = fertilized |> Engine.tick() |> plant_energy_at(1, 1)

    assert fertilized_energy > plain_energy
  end

  test "remove_fertilizer/3 undoes it" do
    state = Engine.new(5, 5) |> Engine.add_fertilizer(1, 1)
    assert %{fertilized: true} = state.tiles[{1, 1}]

    state = Engine.remove_fertilizer(state, 1, 1)
    assert %{fertilized: false} = state.tiles[{1, 1}]
  end

  test "add_fertilizer/3 is a no-op on a rock tile" do
    state = Engine.new(5, 5) |> Engine.place_rock(1, 1) |> Engine.add_fertilizer(1, 1)
    assert %{fertilized: false} = state.tiles[{1, 1}]
  end

  test "release/4 sets a home for the released animal, at its release position" do
    state = Engine.new(5, 5) |> Engine.release(:predator, 2, 3)
    [entity] = Map.values(state.entities)
    assert entity.home == {2, 3}
  end

  test "an animal drifts back toward home once it strays past the territory radius" do
    # This is a test of the homing bound, not predation — a chase can
    # legitimately pull an animal further than the territory radius (the
    # moduledoc for wander/2 says so). Herbivore immigration is
    # unconditional (floor 4, starting from 0), so over 40 ticks one would
    # otherwise show up and get chased. Strip anything but the tracked
    # predator after every tick so it never has prey in sight.
    state = Engine.new(50, 50) |> Engine.release(:predator, 25, 25)
    [id] = Map.keys(state.entities)

    {_state, max_observed} =
      Enum.reduce(1..40, {state, 0}, fn _, {acc, max_dist} ->
        acc = Engine.tick(acc)
        acc = %{acc | entities: Map.take(acc.entities, [id])}

        case Map.get(acc.entities, id) do
          # Well within the ~50-tick starvation window, but don't crash if
          # it somehow didn't survive.
          nil -> {acc, max_dist}
          entity -> {acc, max(max_dist, abs(entity.x - 25) + abs(entity.y - 25))}
        end
      end)

    # territory radius (8) plus a buffer for one diagonal overshoot step
    # before the next tick's correction kicks in.
    assert max_observed <= 10
  end

  test "tick/1 tolerates entities with no home (pre-homing snapshots)" do
    state = Engine.new(10, 10) |> Engine.release(:predator, 5, 5)
    [id] = Map.keys(state.entities)
    state = %{state | entities: %{id => %{state.entities[id] | home: nil}}}

    state = Engine.tick(state)
    assert state.tick == 1
  end

  test "release/4 refuses to place a herbivore on an already-occupied tile" do
    state = Engine.new(5, 5) |> Engine.release(:herbivore, 2, 2)
    assert Enum.count(state.entities) == 1

    state = Engine.release(state, :herbivore, 2, 2)
    assert Enum.count(state.entities) == 1
  end

  test "release/4 allows different kinds to share a tile" do
    state =
      Engine.new(5, 5) |> Engine.release(:herbivore, 2, 2) |> Engine.release(:predator, 2, 2)

    assert Enum.count(state.entities) == 2
  end

  test "scoop/4 refuses to drop onto a tile already holding the same kind" do
    state =
      Engine.new(5, 5)
      |> Engine.release(:herbivore, 1, 1)
      |> Engine.release(:herbivore, 2, 2)

    state = Engine.scoop(state, 1, 1, 2, 2)

    positions = state.entities |> Map.values() |> Enum.map(&{&1.x, &1.y}) |> Enum.sort()
    assert positions == [{1, 1}, {2, 2}]
  end

  test "no two entities of the same kind ever share a tile, across a long run" do
    state =
      Engine.new(30, 30)
      |> scatter(:plant, 60)
      |> scatter(:herbivore, 25)
      |> scatter(:predator, 8)

    Enum.reduce(1..200, state, fn tick, acc ->
      acc = Engine.tick(acc)
      assert_no_same_kind_collisions(acc, tick)
      acc
    end)
  end

  defp scatter(state, :plant, count) do
    Enum.reduce(1..count, state, fn _, acc ->
      x = :rand.uniform(state.width) - 1
      y = :rand.uniform(state.height) - 1
      Engine.plant_seed(acc, x, y, "test")
    end)
  end

  defp scatter(state, kind, count) do
    Enum.reduce(1..count, state, fn _, acc ->
      x = :rand.uniform(state.width) - 1
      y = :rand.uniform(state.height) - 1
      Engine.release(acc, kind, x, y)
    end)
  end

  defp assert_no_same_kind_collisions(state, tick) do
    dupes =
      state.entities
      |> Map.values()
      |> Enum.group_by(&{&1.kind, &1.x, &1.y})
      |> Enum.filter(fn {_key, entities} -> length(entities) > 1 end)

    assert dupes == [], "same-kind collision at tick #{tick}: #{inspect(dupes)}"
  end

  defp plant_energy_at(state, x, y) do
    state.entities
    |> Map.values()
    |> Enum.find(&(&1.kind == :plant and &1.x == x and &1.y == y))
    |> Map.fetch!(:energy)
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
