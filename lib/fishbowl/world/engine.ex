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
  # over a random patch for a few ticks, watering every tile it covers. The
  # patch is grown as a random walk (not a rectangle) so its edges come out
  # ragged, like an actual cloud shadow.
  @rain_chance 0.04
  @rain_target_size 10..20
  @rain_duration 1..3

  # Day/night: a slow global oscillator, purely derived from `state.tick` —
  # no state to persist, no snapshot-compatibility risk. One full cycle
  # takes @day_length_ticks ticks (200 ticks * the 1.5s tick interval is a
  # 5-minute day). Plants grow fastest at midday, slowest at midnight;
  # the range is deliberately mild (0.4x-1.6x) so night is a mood, not a
  # famine.
  @day_length_ticks 200
  @min_daylight_growth 0.4
  @max_daylight_growth 1.6

  # Event log: notable moments worth surfacing next to the raw population
  # numbers — an extinction, a fresh population record, a storm starting.
  # Records only log once a species is thriving, not the trivial "record: 1"
  # the very first time one exists.
  @event_log_length 30
  @record_threshold %{plant: 20, herbivore: 6, predator: 3}

  def new(width, height) do
    tiles =
      for x <- 0..(width - 1), y <- 0..(height - 1), into: %{} do
        {{x, y}, %Tile{}}
      end

    %{
      width: width,
      height: height,
      tick: 0,
      tiles: tiles,
      entities: %{},
      weather: nil,
      events: [],
      records: %{}
    }
  end

  def tick(state) do
    pre_counts = species_counts(state.entities)
    pre_raining? = weather(state) != nil

    state
    |> Map.update!(:tick, &(&1 + 1))
    |> decay_tiles()
    |> tick_entities()
    |> immigrate()
    |> tick_weather()
    |> track_events(pre_counts, pre_raining?)
  end

  @doc "Most recent notable moments first — `%{tick:, icon:, text:}` maps, newest first."
  def events(state), do: Map.get(state, :events, [])

  @doc "0.0 (deepest night) to 1.0 (brightest noon), oscillating over @day_length_ticks ticks."
  def daylight(state) do
    phase = 2 * :math.pi() * state.tick / @day_length_ticks
    (:math.cos(phase) + 1) / 2
  end

  def day?(state), do: daylight(state) >= 0.5

  @doc "The active rain patch, if any — `nil` or `%{tiles: MapSet.t({x, y}), ticks_left: pos_integer}`."
  def weather(state) do
    case Map.get(state, :weather) do
      %{tiles: %MapSet{}, ticks_left: _} = weather -> weather
      # Anything else — nil, or a shape from before rain existed/changed
      # shape — is treated as "not currently raining" rather than crashing.
      _ -> nil
    end
  end

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
        if Tile.passable?(tile) and not occupied_by?(state.entities, {x, y}, kind) do
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

  @doc "Fertilize a tile — plants there grow 3x as fast (see Tile.growth_multiplier/1). No-op on rock."
  def add_fertilizer(state, x, y) do
    Map.update!(state, :tiles, fn tiles ->
      Map.update(tiles, {x, y}, %Tile{}, fn tile ->
        if Tile.passable?(tile), do: %{tile | fertilized: true}, else: tile
      end)
    end)
  end

  def remove_fertilizer(state, x, y) do
    Map.update!(state, :tiles, fn tiles ->
      Map.update(tiles, {x, y}, %Tile{}, &%{&1 | fertilized: false})
    end)
  end

  @doc "Pick up the top entity on a tile and drop it elsewhere (the 'scoop' tool)."
  def scoop(state, from_x, from_y, to_x, to_y) do
    dest = Map.get(state.tiles, {to_x, to_y})

    case {find_at(state.entities, from_x, from_y), dest} do
      {nil, _} -> state
      {_entity, nil} -> state
      {_entity, %Tile{terrain: :rock}} -> state
      {entity, _tile} -> scoop_to(state, entity, to_x, to_y)
    end
  end

  defp scoop_to(state, entity, to_x, to_y) do
    already_there? =
      {entity.x, entity.y} != {to_x, to_y} and
        occupied_by?(state.entities, {to_x, to_y}, entity.kind)

    if already_there?, do: state, else: put_entity(state, %{entity | x: to_x, y: to_y})
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
      case weather(state) do
        nil -> maybe_start_rain(state)
        _weather -> state
      end

    case weather(state) do
      nil ->
        state

      weather ->
        state = water_patch(state, weather.tiles)
        ticks_left = weather.ticks_left - 1
        next = if ticks_left <= 0, do: nil, else: %{weather | ticks_left: ticks_left}
        Map.put(state, :weather, next)
    end
  end

  defp maybe_start_rain(state) do
    if :rand.uniform() < @rain_chance do
      patch = %{
        tiles: random_blob(state, Enum.random(@rain_target_size)),
        ticks_left: Enum.random(@rain_duration)
      }

      Map.put(state, :weather, patch)
    else
      state
    end
  end

  # Grows an irregular patch by repeatedly adding a random unclaimed
  # neighbor of the current blob — a random walk / diffusion-limited
  # growth, not a rectangle, so the outline comes out jagged.
  defp random_blob(state, target_size) do
    start = {:rand.uniform(state.width) - 1, :rand.uniform(state.height) - 1}
    grow_blob(state, MapSet.new([start]), target_size - 1)
  end

  defp grow_blob(_state, blob, remaining) when remaining <= 0, do: blob

  defp grow_blob(state, blob, remaining) do
    candidates =
      blob
      |> Enum.flat_map(fn {x, y} ->
        Enum.map(@directions, fn {dx, dy} -> {x + dx, y + dy} end)
      end)
      |> Enum.uniq()
      |> Enum.filter(fn {x, y} ->
        x in 0..(state.width - 1) and y in 0..(state.height - 1) and
          not MapSet.member?(blob, {x, y})
      end)

    case candidates do
      [] -> blob
      _ -> grow_blob(state, MapSet.put(blob, Enum.random(candidates)), remaining - 1)
    end
  end

  defp water_patch(state, tiles) do
    updated =
      Enum.reduce(tiles, state.tiles, fn pos, acc ->
        Map.update(acc, pos, %Tile{}, &Tile.water/1)
      end)

    %{state | tiles: updated}
  end

  defp species_counts(entities) do
    Enum.reduce(entities, %{plant: 0, herbivore: 0, predator: 0}, fn {_id, e}, acc ->
      Map.update!(acc, e.kind, &(&1 + 1))
    end)
  end

  defp track_events(state, pre_counts, pre_raining?) do
    post_counts = species_counts(state.entities)
    records = Map.get(state, :records, %{})

    {records, species_events} =
      Enum.reduce([:plant, :herbivore, :predator], {records, []}, fn kind, {records, events} ->
        count = Map.get(post_counts, kind, 0)
        prev = Map.get(pre_counts, kind, 0)
        record = Map.get(records, kind, 0)

        events =
          cond do
            count == 0 and prev > 0 ->
              [
                event(
                  state.tick,
                  "💀",
                  "#{species_emoji(kind)} #{species_name(kind)} went extinct"
                )
                | events
              ]

            # record > 0 excludes the very first tick a species is ever
            # seen — otherwise the initial seed population "sets a record"
            # on every boot, which isn't a milestone, just the world
            # starting (and would repeat identically after every restart).
            record > 0 and count > record and count >= @record_threshold[kind] ->
              [
                event(
                  state.tick,
                  "🏆",
                  "population record: #{count} #{species_emoji(kind)} #{species_name(kind)}"
                )
                | events
              ]

            true ->
              events
          end

        {Map.put(records, kind, max(record, count)), events}
      end)

    rain_events =
      if weather(state) != nil and not pre_raining? do
        [event(state.tick, "🌧️", "a storm rolled in")]
      else
        []
      end

    events =
      (rain_events ++ species_events ++ Map.get(state, :events, []))
      |> Enum.take(@event_log_length)

    state
    |> Map.put(:records, records)
    |> Map.put(:events, events)
  end

  defp event(tick, icon, text), do: %{tick: tick, icon: icon, text: text}

  defp species_emoji(:plant), do: "🌱"
  defp species_emoji(:herbivore), do: "🐇"
  defp species_emoji(:predator), do: "🦊"

  defp species_name(:plant), do: "plants"
  defp species_name(:herbivore), do: "herbivores"
  defp species_name(:predator), do: "predators"

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
        fallback = {entity.x, entity.y}
        entity = %{entity | age: entity.age + 1, cooldown: max(entity.cooldown - 1, 0)}
        Map.put(step(entity, state, snapshot), :fallback, fallback)
      end)

    damage_by_id =
      results
      |> Enum.flat_map(& &1.damage)
      |> Enum.group_by(fn {id, _amt} -> id end, fn {_id, amt} -> amt end)
      |> Map.new(fn {id, amounts} -> {id, Enum.sum(amounts)} end)

    # step/3 already steers each entity away from tiles the pre-tick
    # snapshot shows occupied by its own kind, but two movers can still
    # both target the same tile that was vacant in that snapshot. Losing
    # that race reverts to `fallback` (the mover's own pre-tick spot),
    # which is safe by construction: nothing else could have targeted an
    # occupied tile, so nobody else claims it out from under the mover
    # that's backing off.
    entities =
      Enum.reduce(results, %{}, fn %{entity: entity, fallback: fallback}, acc ->
        place_entity(acc, entity, fallback)
      end)

    entities = apply_damage(entities, damage_by_id)

    entities =
      results
      |> Enum.flat_map(& &1.spawn)
      |> Enum.reduce(entities, fn child, acc -> place_child(acc, child) end)

    %{state | entities: entities}
  end

  defp place_entity(acc, nil, _fallback), do: acc

  defp place_entity(acc, entity, {fx, fy}) do
    if occupied_by?(acc, {entity.x, entity.y}, entity.kind) do
      Map.put(acc, entity.id, %{entity | x: fx, y: fy, action: :idle})
    else
      Map.put(acc, entity.id, entity)
    end
  end

  defp place_child(acc, child) do
    if occupied_by?(acc, {child.x, child.y}, child.kind) do
      acc
    else
      Map.put(acc, child.id, child)
    end
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

    growth =
      stats.growth_per_tick * fertility * growth_multiplier_at(state, plant.x, plant.y) *
        daylight_growth_multiplier(state)

    plant = %{
      plant
      | energy: min(stats.max_energy, plant.energy + growth),
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
        {x, y} = step_toward(state, entity.x, entity.y, prey.x, prey.y, entity.kind)
        finish(%{entity | x: x, y: y, action: moved_action(entity, x, y)}, state, stats, [])

      nil ->
        {x, y} = random_step(state, entity.x, entity.y, entity.kind)
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

  defp growth_multiplier_at(state, x, y) do
    case Map.get(state.tiles, {x, y}) do
      %Tile{} = tile -> Tile.growth_multiplier(tile)
      _ -> 1
    end
  end

  defp daylight_growth_multiplier(state) do
    @min_daylight_growth + daylight(state) * (@max_daylight_growth - @min_daylight_growth)
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

  # `kind` here is the mover's own kind: a herbivore may step onto a tile
  # with a plant (different kind, that's how it eats) but never onto a tile
  # already holding another herbivore. Checked against the pre-tick
  # snapshot, since that's all a single entity's step/3 call can see —
  # tick_entities' post-hoc placement pass (place_entity/3) is what catches
  # the rarer case of two movers racing for the same then-vacant tile.
  defp step_toward(state, x, y, tx, ty, kind) do
    dx = clamp_step(tx - x)
    dy = clamp_step(ty - y)

    if free_for?(state, x + dx, y + dy, kind) do
      {x + dx, y + dy}
    else
      random_step(state, x, y, kind)
    end
  end

  defp clamp_step(d) when d > 0, do: 1
  defp clamp_step(d) when d < 0, do: -1
  defp clamp_step(_), do: 0

  defp random_step(state, x, y, kind) do
    @directions
    |> Enum.shuffle()
    |> Enum.find(nil, fn {dx, dy} -> free_for?(state, x + dx, y + dy, kind) end)
    |> case do
      {dx, dy} -> {x + dx, y + dy}
      nil -> {x, y}
    end
  end

  defp random_free_neighbor(state, x, y, kind) do
    @directions
    |> Enum.shuffle()
    |> Enum.find(fn {dx, dy} -> free_for?(state, x + dx, y + dy, kind) end)
    |> case do
      {dx, dy} -> {x + dx, y + dy}
      nil -> nil
    end
  end

  defp free_for?(state, x, y, kind) do
    passable(state, x, y) and not occupied_by?(state.entities, {x, y}, kind)
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
