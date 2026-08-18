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
end
