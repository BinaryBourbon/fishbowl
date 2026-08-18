defmodule Fishbowl.World.Tile do
  @moduledoc """
  A single grid cell. Terrain is static-ish (players can place/remove rocks),
  fertility drives plant growth chance and decays slowly unless watered.
  """

  @derive Jason.Encoder
  defstruct terrain: :soil,
            fertility: 0.3,
            tint: nil,
            fertilized: false

  @type terrain :: :soil | :rock
  @type t :: %__MODULE__{
          terrain: terrain(),
          fertility: float(),
          tint: nil | String.t(),
          fertilized: boolean()
        }

  @fertilizer_growth_multiplier 3

  def passable?(%__MODULE__{terrain: :rock}), do: false
  def passable?(%__MODULE__{}), do: true

  def water(tile), do: %{tile | fertility: min(1.0, tile.fertility + 0.35)}

  def decay(tile), do: %{tile | fertility: max(0.0, tile.fertility - 0.002)}

  def growth_multiplier(%__MODULE__{fertilized: true}), do: @fertilizer_growth_multiplier
  def growth_multiplier(%__MODULE__{}), do: 1
end
