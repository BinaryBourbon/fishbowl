defmodule FishbowlWeb.WorldLiveTest do
  use FishbowlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders the grid", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Fishbowl"
    assert html =~ ~s(class="board")
  end

  test "seed tool plants on click", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element(~s([phx-value-tool="seed"]))
    |> render_click()

    view
    |> element(~s([phx-value-x="3"][phx-value-y="3"]))
    |> render_click()

    Process.sleep(50)
    state = Fishbowl.World.get_state()

    assert Enum.any?(state.entities, fn {_id, e} -> e.kind == :plant and e.x == 3 and e.y == 3 end)
  end

  test "rock tool blocks the tile from planting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element(~s([phx-value-tool="rock"])) |> render_click()
    view |> element(~s([phx-value-x="10"][phx-value-y="10"])) |> render_click()

    Process.sleep(50)
    assert %{terrain: :rock} = Map.get(Fishbowl.World.get_state().tiles, {10, 10})
  end

  test "herbivore tool releases a rabbit on click", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    before_count = count_kind(:herbivore)

    view |> element(~s([phx-value-tool="herbivore"])) |> render_click()
    view |> element(~s([phx-value-x="15"][phx-value-y="15"])) |> render_click()

    # Count only, not exact position: the world's own tick loop keeps
    # running during tests, and a released animal can wander off its spawn
    # tile before the assertion runs — that's expected simulation behavior,
    # not something to pin the test to.
    Process.sleep(50)
    assert count_kind(:herbivore) > before_count
  end

  test "predator tool releases a fox on click", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    before_count = count_kind(:predator)

    view |> element(~s([phx-value-tool="predator"])) |> render_click()
    view |> element(~s([phx-value-x="16"][phx-value-y="16"])) |> render_click()

    Process.sleep(50)
    assert count_kind(:predator) > before_count
  end

  defp count_kind(kind) do
    Fishbowl.World.get_state().entities
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end

  test "grid locks both row and column tracks to the world dimensions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "grid-template-columns: repeat(60, 1fr)"
    assert html =~ "grid-template-rows: repeat(40, 1fr)"
  end
end
