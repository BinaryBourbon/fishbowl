defmodule Fishbowl.World.Entity do
  @moduledoc """
  A living thing on the grid. Plants, herbivores and predators are all the
  same struct with different `kind` — the engine dispatches tick behavior
  by kind. Keeping this as data (not a process) so v1 ticks in one pass.
  """

  @derive Jason.Encoder
  defstruct [:id, :kind, :x, :y, :energy, :age, :cooldown, action: :spawned, home: nil]

  @type kind :: :plant | :herbivore | :predator
  @type action :: :spawned | :idle | :moved | :ate | :reproduced
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          x: integer(),
          y: integer(),
          energy: float(),
          age: non_neg_integer(),
          cooldown: non_neg_integer(),
          action: action(),
          home: nil | {integer(), integer()}
        }

  @species %{
    plant: %{
      start_energy: 10.0,
      max_energy: 30.0,
      reproduce_energy: 18.0,
      reproduce_cooldown: 5,
      growth_per_tick: 1.2
    },
    herbivore: %{
      start_energy: 40.0,
      max_energy: 100.0,
      reproduce_energy: 60.0,
      reproduce_cooldown: 10,
      metabolism: 1.0,
      bite: 8.0,
      sight: 6
    },
    predator: %{
      start_energy: 60.0,
      max_energy: 140.0,
      reproduce_energy: 110.0,
      reproduce_cooldown: 18,
      metabolism: 1.2,
      bite: 22.0,
      sight: 6
    }
  }

  def species(kind), do: Map.fetch!(@species, kind)

  def new(kind, x, y) do
    stats = species(kind)

    %__MODULE__{
      id: unique_id(),
      kind: kind,
      x: x,
      y: y,
      energy: stats.start_energy,
      age: 0,
      cooldown: 0,
      home: home_for(kind, x, y)
    }
  end

  # Where it was born/released/immigrated — animals drift back here when
  # not actively hunting, which is what turns "pure random walk" into
  # loose territories/packs. Plants don't move, so no home to speak of.
  defp home_for(kind, x, y) when kind in [:herbivore, :predator], do: {x, y}
  defp home_for(_kind, _x, _y), do: nil

  def alive?(%__MODULE__{energy: energy}), do: energy > 0

  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
