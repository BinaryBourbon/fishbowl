defmodule Fishbowl.World.EngineTest do
  use ExUnit.Case, async: true

  alias Fishbowl.World.Engine

  test "release/4 drops a herbivore or predator on a passable tile" do
    state = Engine.new(5, 5)

    state = Engine.release(state, :herbivore, 1, 1)
    assert Enum.any?(state.entities, fn {_id, e} -> e.kind == :herbivore and e.x == 1 and e.y == 1 end)

    state = Engine.release(state, :predator, 2, 2)
    assert Enum.any?(state.entities, fn {_id, e} -> e.kind == :predator and e.x == 2 and e.y == 2 end)
  end

  test "release/4 is a no-op on a rock tile" do
    state = Engine.new(5, 5) |> Engine.place_rock(1, 1)

    state = Engine.release(state, :herbivore, 1, 1)
    refute Enum.any?(state.entities, fn {_id, e} -> e.x == 1 and e.y == 1 end)
  end
end
