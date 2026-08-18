defmodule Fishbowl.World.Tile do
  @moduledoc """
  A single grid cell. Terrain is static-ish (players can place/remove rocks),
  fertility drives plant growth chance and decays slowly unless watered.
  """

  @derive Jason.Encoder
  defstruct terrain: :soil,
            fertility: 0.3,
            tint: nil,
            tint_ticks_left: 0,
            fertilized: false

  @type terrain :: :soil | :rock
  @type t :: %__MODULE__{
          terrain: terrain(),
          fertility: float(),
          tint: nil | String.t(),
          tint_ticks_left: non_neg_integer(),
          fertilized: boolean()
        }

  @fertilizer_growth_multiplier 3

  # How long a planting tint lasts — a recency signal ("someone built a
  # forest here last night"), not a permanent mark. Without this it only
  # ever accumulates: 310 of 2400 tiles were already tinted and climbing
  # before this existed, per a live report that it was making the board
  # hard to read.
  @tint_duration 300

  def passable?(%__MODULE__{terrain: :rock}), do: false
  def passable?(%__MODULE__{}), do: true

  def water(tile), do: %{tile | fertility: min(1.0, tile.fertility + 0.35)}

  def tint(tile, player_id), do: %{tile | tint: player_id, tint_ticks_left: @tint_duration}

  def decay(tile) do
    %{tile | fertility: max(0.0, tile.fertility - 0.002)}
    |> decay_tint()
  end

  defp decay_tint(%{tint: nil} = tile), do: tile

  defp decay_tint(%{tint_ticks_left: left} = tile) when left <= 1,
    do: %{tile | tint: nil, tint_ticks_left: 0}

  defp decay_tint(tile), do: %{tile | tint_ticks_left: tile.tint_ticks_left - 1}

  def growth_multiplier(%__MODULE__{fertilized: true}), do: @fertilizer_growth_multiplier
  def growth_multiplier(%__MODULE__{}), do: 1
end
