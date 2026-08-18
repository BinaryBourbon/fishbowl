defmodule Fishbowl.World do
  @moduledoc """
  Owns the world state and drives the tick. Entities live as structs inside
  this single process (no per-entity processes for v1 — see the design
  notes in the README). Other processes read state via `get_state/0` and
  mutate it via the player-action calls; every tick and every mutation is
  broadcast over PubSub so LiveView can stay in sync without any custom
  sync logic.
  """

  use GenServer

  alias Fishbowl.World.{Engine, Snapshot}

  @width 60
  @height 40
  @tick_interval 500
  @snapshot_every_ticks 20
  @topic "world"

  # --- Client API -------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic
  def width, do: @width
  def height, do: @height

  def get_state, do: GenServer.call(__MODULE__, :get_state)

  def plant_seed(x, y, player_id), do: GenServer.cast(__MODULE__, {:plant_seed, x, y, player_id})
  def release(kind, x, y), do: GenServer.cast(__MODULE__, {:release, kind, x, y})
  def water(x, y), do: GenServer.cast(__MODULE__, {:water, x, y})
  def place_rock(x, y), do: GenServer.cast(__MODULE__, {:place_rock, x, y})
  def remove_rock(x, y), do: GenServer.cast(__MODULE__, {:remove_rock, x, y})
  def scoop(from_x, from_y, to_x, to_y), do: GenServer.cast(__MODULE__, {:scoop, from_x, from_y, to_x, to_y})

  # --- Server -------------------------------------------------------------

  @impl true
  def init(_opts) do
    state =
      case Snapshot.load() do
        {:ok, %{width: @width, height: @height} = loaded} -> loaded
        _ -> seed_world()
      end

    schedule_tick()
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:plant_seed, x, y, player_id}, state) do
    broadcast_mutate(Engine.plant_seed(state, x, y, player_id))
  end

  def handle_cast({:release, kind, x, y}, state), do: broadcast_mutate(Engine.release(state, kind, x, y))
  def handle_cast({:water, x, y}, state), do: broadcast_mutate(Engine.water(state, x, y))
  def handle_cast({:place_rock, x, y}, state), do: broadcast_mutate(Engine.place_rock(state, x, y))
  def handle_cast({:remove_rock, x, y}, state), do: broadcast_mutate(Engine.remove_rock(state, x, y))

  def handle_cast({:scoop, fx, fy, tx, ty}, state) do
    broadcast_mutate(Engine.scoop(state, fx, fy, tx, ty))
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    new_state = Engine.tick(state)
    Phoenix.PubSub.broadcast(Fishbowl.PubSub, @topic, {:world_tick, new_state})

    if rem(new_state.tick, @snapshot_every_ticks) == 0 do
      Snapshot.save(new_state)
    end

    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    Snapshot.save(state)
    :ok
  end

  defp broadcast_mutate(new_state) do
    Phoenix.PubSub.broadcast(Fishbowl.PubSub, @topic, {:world_tick, new_state})
    {:noreply, new_state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)

  defp seed_world do
    state = Engine.new(@width, @height)

    state
    |> scatter(:plant, 160)
    |> scatter(:herbivore, 26)
    |> scatter(:predator, 5)
  end

  defp scatter(state, kind, count) do
    Enum.reduce(1..count, state, fn _, acc ->
      x = :rand.uniform(@width) - 1
      y = :rand.uniform(@height) - 1
      entity = Fishbowl.World.Entity.new(kind, x, y)
      %{acc | entities: Map.put(acc.entities, entity.id, entity)}
    end)
  end
end
