defmodule FishbowlWeb.WorldLive do
  @moduledoc """
  The whole game: renders the grid, handles gardener tool clicks, and stays
  in sync purely by subscribing to `Fishbowl.World`'s PubSub broadcasts.
  No client-specific sync logic — every connected LiveView just reflects
  whatever the World process last broadcast.
  """

  use FishbowlWeb, :live_view

  alias Fishbowl.World
  alias FishbowlWeb.Presence

  @history_length 120

  @palette [
    "#f97316",
    "#ec4899",
    "#8b5cf6",
    "#06b6d4",
    "#22c55e",
    "#eab308",
    "#ef4444",
    "#3b82f6"
  ]

  @tools [
    {:seed, "🌱", "Seed"},
    {:water, "💧", "Water"},
    {:rock, "🪨", "Rock"},
    {:scoop, "🤲", "Scoop"},
    {:herbivore, "🐇", "Release rabbit"},
    {:predator, "🦊", "Release fox"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    player_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    color = color_for(player_id)
    world = World.get_state()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Fishbowl.PubSub, World.topic())

      {:ok, _} =
        Presence.track(self(), World.topic(), player_id, %{
          color: color,
          joined_at: System.system_time(:second)
        })
    end

    socket =
      socket
      |> assign(
        player_id: player_id,
        color: color,
        tool: :seed,
        scoop_from: nil,
        width: World.width(),
        height: World.height(),
        tools: @tools,
        presences: list_presences(),
        history: []
      )
      |> assign_world(world)

    {:ok, socket}
  end

  @impl true
  def handle_info({:world_tick, world}, socket), do: {:noreply, assign_world(socket, world)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, presences: list_presences())}
  end

  @impl true
  def handle_event("select_tool", %{"tool" => tool}, socket) do
    {:noreply, assign(socket, tool: String.to_existing_atom(tool), scoop_from: nil)}
  end

  def handle_event("cell_click", %{"x" => xs, "y" => ys}, socket) do
    x = String.to_integer(xs)
    y = String.to_integer(ys)

    case socket.assigns.tool do
      :seed ->
        World.plant_seed(x, y, socket.assigns.player_id)
        {:noreply, socket}

      :water ->
        World.water(x, y)
        {:noreply, socket}

      :rock ->
        if rock?(socket.assigns.world, x, y) do
          World.remove_rock(x, y)
        else
          World.place_rock(x, y)
        end

        {:noreply, socket}

      :scoop ->
        handle_scoop_click(socket, x, y)

      kind when kind in [:herbivore, :predator] ->
        World.release(kind, x, y)
        {:noreply, socket}
    end
  end

  defp handle_scoop_click(%{assigns: %{scoop_from: nil}} = socket, x, y) do
    if occupant_at(socket.assigns.world, x, y) do
      {:noreply, assign(socket, scoop_from: {x, y})}
    else
      {:noreply, socket}
    end
  end

  defp handle_scoop_click(%{assigns: %{scoop_from: {fx, fy}}} = socket, x, y) do
    World.scoop(fx, fy, x, y)
    {:noreply, assign(socket, scoop_from: nil)}
  end

  defp assign_world(socket, world) do
    counts = species_counts(world)

    socket
    |> assign(world: world, cells: build_cells(world))
    |> update(:history, fn history ->
      Enum.take([counts | history], @history_length)
    end)
  end

  defp species_counts(world) do
    world.entities
    |> Map.values()
    |> Enum.reduce(%{plant: 0, herbivore: 0, predator: 0}, fn e, acc ->
      Map.update!(acc, e.kind, &(&1 + 1))
    end)
  end

  # --- Grid building ------------------------------------------------------

  @occupant_priority %{predator: 0, herbivore: 1, plant: 2}

  defp build_cells(world) do
    by_pos = Enum.group_by(world.entities, fn {_id, e} -> {e.x, e.y} end, fn {_id, e} -> e end)

    for y <- 0..(world.height - 1), x <- 0..(world.width - 1) do
      tile = Map.fetch!(world.tiles, {x, y})
      occupant = by_pos |> Map.get({x, y}, []) |> top_occupant()

      %{
        x: x,
        y: y,
        terrain: tile.terrain,
        fertility: tile.fertility,
        tint: tile.tint && color_for(tile.tint),
        occupant: occupant
      }
    end
  end

  defp top_occupant([]), do: nil

  defp top_occupant(entities) do
    Enum.min_by(entities, &Map.fetch!(@occupant_priority, &1.kind))
  end

  defp occupant_at(world, x, y) do
    Enum.find_value(world.entities, fn {_id, e} -> e.x == x and e.y == y and e end)
  end

  defp rock?(world, x, y) do
    match?(%{terrain: :rock}, Map.get(world.tiles, {x, y}))
  end

  defp emoji(:plant), do: "🌱"
  defp emoji(:herbivore), do: "🐇"
  defp emoji(:predator), do: "🦊"
  defp emoji(nil), do: ""

  # What did the occupant do last tick? :idle gets no visual — everything
  # else (spawned/moved/ate/reproduced) is rare enough per-entity that a
  # badge stays informative instead of turning into background noise.
  defp action_class(nil), do: ""
  defp action_class(%{action: action}), do: "action-#{action}"

  defp badge(%{action: :spawned}), do: "✨"
  defp badge(%{action: :reproduced}), do: "💗"
  defp badge(%{action: :ate}), do: "🍴"
  defp badge(_), do: nil

  defp soil_color(fertility) do
    # Dry soil -> lush green as fertility rises from 0 to 1.
    green = trunc(70 + fertility * 110)
    "rgb(#{trunc(90 - fertility * 40)}, #{green}, #{trunc(60 - fertility * 20)})"
  end

  defp color_for(id) do
    Enum.at(@palette, :erlang.phash2(id, length(@palette)))
  end

  defp list_presences do
    World.topic()
    |> Presence.list()
    |> Enum.map(fn {id, %{metas: [meta | _]}} -> Map.put(meta, :id, id) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fishbowl">
      <header class="toolbar">
        <h1>🌿 Fishbowl</h1>
        <div class="tools">
          <button
            :for={{key, icon, label} <- @tools}
            type="button"
            class={"tool #{if @tool == key, do: "active"}"}
            phx-click="select_tool"
            phx-value-tool={key}
          >
            <span class="icon">{icon}</span> {label}
          </button>
        </div>
        <div class="presence" title="players here now">
          <span :for={p <- @presences} class="dot" style={"background:#{p.color}"}></span>
          <span class="count">{length(@presences)} here</span>
        </div>
      </header>

      <div
        class="board"
        style={"grid-template-columns: repeat(#{@width}, 1fr); grid-template-rows: repeat(#{@height}, 1fr); aspect-ratio: #{@width} / #{@height};"}
      >
        <div
          :for={cell <- @cells}
          class={"cell #{cell.terrain} #{action_class(cell.occupant)} #{if @tool == :scoop and @scoop_from == {cell.x, cell.y}, do: "selected"}"}
          style={"background:#{if cell.terrain == :rock, do: "#57534e", else: soil_color(cell.fertility)}; #{if cell.tint, do: "box-shadow: inset 0 0 0 2px #{cell.tint};"}"}
          phx-click="cell_click"
          phx-value-x={cell.x}
          phx-value-y={cell.y}
        >
          {emoji(cell.occupant && cell.occupant.kind)}<span :if={badge(cell.occupant)} class="badge">{badge(
            cell.occupant
          )}</span>
        </div>
      </div>

      <footer class="stats">
        <.population_graph history={@history} />
        <div class="legend">
          <span>🌱 {current_count(@history, :plant)}</span>
          <span>🐇 {current_count(@history, :herbivore)}</span>
          <span>🦊 {current_count(@history, :predator)}</span>
          <span class="tick">tick {@world.tick}</span>
        </div>
      </footer>
    </div>
    """
  end

  defp current_count([current | _], key), do: Map.get(current, key, 0)
  defp current_count([], _key), do: 0

  defp population_graph(assigns) do
    samples = Enum.reverse(assigns.history)
    max_count = samples |> Enum.flat_map(&Map.values/1) |> Enum.max(fn -> 1 end) |> max(1)

    assigns =
      assign(assigns,
        max_count: max_count,
        plant_points: points(samples, :plant, max_count),
        herbivore_points: points(samples, :herbivore, max_count),
        predator_points: points(samples, :predator, max_count)
      )

    ~H"""
    <svg viewBox="0 0 240 40" class="graph" preserveAspectRatio="none">
      <polyline points={@plant_points} fill="none" stroke="#22c55e" stroke-width="1.5" />
      <polyline points={@herbivore_points} fill="none" stroke="#a3a3a3" stroke-width="1.5" />
      <polyline points={@predator_points} fill="none" stroke="#ef4444" stroke-width="1.5" />
    </svg>
    """
  end

  defp points(samples, key, max_count) do
    n = max(length(samples) - 1, 1)

    samples
    |> Enum.with_index()
    |> Enum.map(fn {sample, i} ->
      x = i / n * 240
      y = 40 - Map.get(sample, key, 0) / max_count * 40
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end
end
