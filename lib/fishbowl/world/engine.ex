defmodule Fishbowl.World.Engine do
  @moduledoc """
  Pure functions over world state. No process, no I/O — easy to test and
  easy to reason about. `Fishbowl.World` (the GenServer) owns the state and
  calls `tick/1` on an interval (see `Fishbowl.World`'s `@tick_interval`).

  Each tick, every entity computes its next state from a single snapshot
  (so order of iteration never matters). Eating doesn't mutate the prey
  directly — it records damage, which is applied in a second pass after
  every entity has acted. That keeps "who ate whom" independent of map
  iteration order.
  """

  alias Fishbowl.World.{Entity, Tile}

  @directions [{0, -1}, {0, 1}, {-1, 0}, {1, 0}, {-1, -1}, {-1, 1}, {1, -1}, {1, 1}]

  # Below these floors, each tick has a chance to immigrate one individual —
  # a trickle from "outside the grid" so a local extinction (very much
  # intended as emergent content) doesn't leave the world permanently dead
  # when no one's around to replant it.
  @immigration_floor %{plant: 15, herbivore: 4, predator: 2}
  @immigration_chance 0.15

  # Rain: while no storm is active, each tick has a small chance to start one
  # over a random ~4x4 patch for a few ticks, watering every tile it covers.
  @rain_chance 0.04
  @rain_size 3..5
  @rain_duration 1..3

  def new(width, height) do
    tiles =
      for x <- 0..(width - 1), y <- 0..(height - 1), into: %{} do
        {{x, y}, %Tile{}}
      end

    %{width: width, height: height, tick: 0, tiles: tiles, entities: %{}, weather: nil}
  end

  def tick(state) do
    state
    |> Map.update!(:tick, &(&1 + 1))
    |> decay_tiles()
    |> tick_entities()
    |> immigrate()
    |> tick_weather()
  end

  @doc "The active rain patch, if any — `nil` or `%{x:, y:, w:, h:, ticks_left:}`."
  def weather(state), do: Map.get(state, :weather)

  # --- Player actions -------------------------------------------------

  def plant_seed(state, x, y, player_id) do
    key = {x, y}

    with tile when not is_nil(tile) <- Map.get(state.tiles, key),
         true <- Tile.passable?(tile),
         false <- occupied_by?(state.entities, key, :plant) do
      plant = Entity.new(:plant, x, y)
      tiles = Map.update!(state.tiles, key, &%{&1 | tint: player_id})
      %{state | entities: Map.put(state.entities, plant.id, plant), tiles: tiles}
    else
      _ -> state
    end
  end

  @doc "Drop a herbivore or predator on a tile — how players restock the ecosystem after a local extinction."
  def release(state, kind, x, y) when kind in [:herbivore, :predator] do
    case Map.get(state.tiles, {x, y}) do
      tile when not is_nil(tile) ->
        if Tile.passable?(tile) do
          animal = Entity.new(kind, x, y)
          %{state | entities: Map.put(state.entities, animal.id, animal)}
        else
          state
        end

      nil ->
        state
    end
  end

  def water(state, x, y) do
    Map.update!(state, :tiles, fn tiles ->
      Map.update(tiles, {x, y}, %Tile{}, &Tile.water/1)
    end)
  end

  def place_rock(state, x, y) do
    key = {x, y}

    entities =
      state.entities
      |> Enum.reject(fn {_id, e} -> e.x == x and e.y == y end)
      |> Map.new()

    tiles = Map.update(state.tiles, key, %Tile{terrain: :rock}, &%{&1 | terrain: :rock})
    %{state | tiles: tiles, entities: entities}
  end

  def remove_rock(state, x, y) do
    Map.update!(state, :tiles, fn tiles ->
      Map.update(tiles, {x, y}, %Tile{}, &%{&1 | terrain: :soil})
    end)
  end

  @doc "Pick up the top entity on a tile and drop it elsewhere (the 'scoop' tool)."
  def scoop(state, from_x, from_y, to_x, to_y) do
    dest = Map.get(state.tiles, {to_x, to_y})

    case {find_at(state.entities, from_x, from_y), dest} do
      {nil, _} -> state
      {_entity, nil} -> state
      {_entity, %Tile{terrain: :rock}} -> state
      {entity, _tile} -> put_entity(state, %{entity | x: to_x, y: to_y})
    end
  end

  defp put_entity(state, entity),
    do: %{state | entities: Map.put(state.entities, entity.id, entity)}

  # --- Tick internals ---------------------------------------------------

  defp decay_tiles(state) do
    tiles =
      Map.new(state.tiles, fn {pos, tile} ->
        {pos, if(tile.terrain == :rock, do: tile, else: Tile.decay(tile))}
      end)

    %{state | tiles: tiles}
  end

  defp immigrate(state) do
    counts = species_counts(state.entities)

    Enum.reduce([:plant, :herbivore, :predator], state, fn kind, acc ->
      if Map.get(counts, kind, 0) < @immigration_floor[kind] and
           :rand.uniform() < @immigration_chance do
        case random_free_tile(acc, kind) do
          nil ->
            acc

          {x, y} ->
            immigrant = Entity.new(kind, x, y)
            %{acc | entities: Map.put(acc.entities, immigrant.id, immigrant)}
        end
      else
        acc
      end
    end)
  end

  defp tick_weather(state) do
    state =
      case Map.get(state, :weather) do
        nil -> maybe_start_rain(state)
        _weather -> state
      end

    case Map.get(state, :weather) do
      nil ->
        state

      weather ->
        state = water_patch(state, weather)
        ticks_left = weather.ticks_left - 1
        next = if ticks_left <= 0, do: nil, else: %{weather | ticks_left: ticks_left}
        Map.put(state, :weather, next)
    end
  end

  defp maybe_start_rain(state) do
    if :rand.uniform() < @rain_chance do
      w = Enum.random(@rain_size)
      h = Enum.random(@rain_size)
      x = :rand.uniform(max(state.width - w + 1, 1)) - 1
      y = :rand.uniform(max(state.height - h + 1, 1)) - 1

      patch = %{
        x: x,
        y: y,
        w: min(w, state.width),
        h: min(h, state.height),
        ticks_left: Enum.random(@rain_duration)
      }

      Map.put(state, :weather, patch)
    else
      state
    end
  end

  defp water_patch(state, %{x: x0, y: y0, w: w, h: h}) do
    tiles =
      Enum.reduce(x0..(x0 + w - 1), state.tiles, fn x, tiles ->
        Enum.reduce(y0..(y0 + h - 1), tiles, fn y, tiles ->
          Map.update(tiles, {x, y}, %Tile{}, &Tile.water/1)
        end)
      end)

    %{state | tiles: tiles}
  end

  defp species_counts(entities) do
    Enum.reduce(entities, %{plant: 0, herbivore: 0, predator: 0}, fn {_id, e}, acc ->
      Map.update!(acc, e.kind, &(&1 + 1))
    end)
  end

  defp random_free_tile(state, kind, attempts \\ 20)
  defp random_free_tile(_state, _kind, 0), do: nil

  defp random_free_tile(state, kind, attempts) do
    x = :rand.uniform(state.width) - 1
    y = :rand.uniform(state.height) - 1

    if passable(state, x, y) and not occupied_by?(state.entities, {x, y}, kind) do
      {x, y}
    else
      random_free_tile(state, kind, attempts - 1)
    end
  end

  defp tick_entities(state) do
    snapshot = state.entities

    results =
      Enum.map(snapshot, fn {_id, entity} ->
        entity = %{entity | age: entity.age + 1, cooldown: max(entity.cooldown - 1, 0)}
        step(entity, state, snapshot)
      end)

    damage_by_id =
      results
      |> Enum.flat_map(& &1.damage)
      |> Enum.group_by(fn {id, _amt} -> id end, fn {_id, amt} -> amt end)
      |> Map.new(fn {id, amounts} -> {id, Enum.sum(amounts)} end)

    entities =
      Enum.reduce(results, %{}, fn %{entity: entity}, acc ->
        if entity, do: Map.put(acc, entity.id, entity), else: acc
      end)

    entities = apply_damage(entities, damage_by_id)

    entities =
      results
      |> Enum.flat_map(& &1.spawn)
      |> Enum.reduce(entities, fn child, acc -> Map.put(acc, child.id, child) end)

    %{state | entities: entities}
  end

  defp apply_damage(entities, damage_by_id) do
    Enum.reduce(damage_by_id, entities, fn {id, dmg}, acc ->
      case Map.get(acc, id) do
        nil ->
          acc

        entity ->
          remaining = entity.energy - dmg

          if remaining <= 0,
            do: Map.delete(acc, id),
            else: Map.put(acc, id, %{entity | energy: remaining})
      end
    end)
  end

  defp step(%Entity{kind: :plant} = plant, state, _snapshot) do
    stats = Entity.species(:plant)
    fertility = fertility_at(state, plant.x, plant.y)

    plant = %{
      plant
      | energy: min(stats.max_energy, plant.energy + stats.growth_per_tick * fertility),
        action: :idle
    }

    spawn =
      if plant.energy >= stats.reproduce_energy and plant.cooldown == 0 and
           :rand.uniform() < fertility do
        case random_free_neighbor(state, plant.x, plant.y, :plant) do
          nil -> []
          {nx, ny} -> [Entity.new(:plant, nx, ny)]
        end
      else
        []
      end

    plant =
      if spawn == [],
        do: plant,
        else: %{plant | cooldown: stats.reproduce_cooldown, action: :reproduced}

    %{entity: plant, spawn: spawn, damage: []}
  end

  defp step(%Entity{kind: kind} = entity, state, snapshot) when kind in [:herbivore, :predator] do
    prey_kind = if kind == :herbivore, do: :plant, else: :herbivore
    stats = Entity.species(kind)
    energy = entity.energy - stats.metabolism

    if energy <= 0 do
      %{entity: nil, spawn: [], damage: []}
    else
      entity = %{entity | energy: energy}
      forage(entity, state, snapshot, prey_kind, stats)
    end
  end

  defp forage(entity, state, snapshot, prey_kind, stats) do
    case nearest(snapshot, entity, prey_kind, stats.sight) do
      {prey_id, prey} when prey.x == entity.x and prey.y == entity.y ->
        gained = min(prey.energy, stats.bite)
        entity = %{entity | energy: min(stats.max_energy, entity.energy + gained), action: :ate}
        finish(entity, state, stats, [{prey_id, stats.bite}])

      {_prey_id, prey} ->
        {x, y} = step_toward(state, entity.x, entity.y, prey.x, prey.y)
        finish(%{entity | x: x, y: y, action: moved_action(entity, x, y)}, state, stats, [])

      nil ->
        {x, y} = random_step(state, entity.x, entity.y)
        finish(%{entity | x: x, y: y, action: moved_action(entity, x, y)}, state, stats, [])
    end
  end

  defp moved_action(entity, x, y) when entity.x == x and entity.y == y, do: :idle
  defp moved_action(_entity, _x, _y), do: :moved

  defp finish(entity, state, stats, damage) do
    spawn =
      if entity.energy >= stats.reproduce_energy and entity.cooldown == 0 do
        case random_free_neighbor(state, entity.x, entity.y, entity.kind) do
          nil -> []
          {nx, ny} -> [Entity.new(entity.kind, nx, ny)]
        end
      else
        []
      end

    entity =
      if spawn == [] do
        entity
      else
        %{
          entity
          | energy: entity.energy * 0.5,
            cooldown: stats.reproduce_cooldown,
            action: :reproduced
        }
      end

    %{entity: entity, spawn: spawn, damage: damage}
  end

  defp fertility_at(state, x, y) do
    case Map.get(state.tiles, {x, y}) do
      %Tile{fertility: f} -> max(f, 0.05)
      _ -> 0.05
    end
  end

  defp nearest(snapshot, entity, kind, sight) do
    snapshot
    |> Enum.filter(fn {_id, e} -> e.kind == kind end)
    |> Enum.map(fn {id, e} -> {dist(entity, e), id, e} end)
    |> Enum.filter(fn {d, _id, _e} -> d <= sight end)
    |> Enum.sort_by(fn {d, _id, _e} -> d end)
    |> case do
      [{_d, id, e} | _] -> {id, e}
      [] -> nil
    end
  end

  defp dist(%{x: x1, y: y1}, %{x: x2, y: y2}), do: abs(x1 - x2) + abs(y1 - y2)

  defp step_toward(state, x, y, tx, ty) do
    dx = clamp_step(tx - x)
    dy = clamp_step(ty - y)

    case passable(state, x + dx, y + dy) do
      true -> {x + dx, y + dy}
      false -> random_step(state, x, y)
    end
  end

  defp clamp_step(d) when d > 0, do: 1
  defp clamp_step(d) when d < 0, do: -1
  defp clamp_step(_), do: 0

  defp random_step(state, x, y) do
    @directions
    |> Enum.shuffle()
    |> Enum.find(nil, fn {dx, dy} -> passable(state, x + dx, y + dy) end)
    |> case do
      {dx, dy} -> {x + dx, y + dy}
      nil -> {x, y}
    end
  end

  defp random_free_neighbor(state, x, y, kind) do
    @directions
    |> Enum.shuffle()
    |> Enum.find(fn {dx, dy} ->
      nx = x + dx
      ny = y + dy
      passable(state, nx, ny) and not occupied_by?(state.entities, {nx, ny}, kind)
    end)
    |> case do
      {dx, dy} -> {x + dx, y + dy}
      nil -> nil
    end
  end

  defp passable(state, x, y) do
    x in 0..(state.width - 1) and y in 0..(state.height - 1) and
      Tile.passable?(Map.get(state.tiles, {x, y}, %Tile{terrain: :rock}))
  end

  defp occupied_by?(entities, {x, y}, kind) do
    Enum.any?(entities, fn {_id, e} -> e.kind == kind and e.x == x and e.y == y end)
  end

  defp find_at(entities, x, y) do
    Enum.find_value(entities, fn {_id, e} -> if e.x == x and e.y == y, do: e end)
  end
end
