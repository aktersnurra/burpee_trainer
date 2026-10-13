defmodule BurpeeTrainerWeb.HistoryWorkspaceTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  test "chart positions saved sessions against the route load time, not the newest session", %{
    conn: conn
  } do
    user = user_fixture()

    saved =
      %BurpeeTrainer.Workouts.WorkoutSession{
        user_id: user.id,
        state: :completed,
        source_kind: :manual,
        display_name_snapshot: "Saved",
        workout_type_snapshot: :six_count,
        burpee_type: :six_count,
        burpee_count_actual: 20,
        duration_sec_actual: 1200,
        completed_at: DateTime.add(DateTime.utc_now(:second), -7 * 86400),
        capture_mode: :logged
      }
      |> BurpeeTrainer.Repo.insert!()

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/progress")

    [style] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-history-point-#{saved.id}")
      |> LazyHTML.attribute("style")

    [_, left] = Regex.run(~r/left: ([0-9.]+)%/, style)
    assert String.to_float(left) < 94.0
    assert %DateTime{} = :sys.get_state(view.pid).socket.assigns.home_snapshot_now
  end

  test "route, period and busy boundary chart geometry use History's distinct genuine clock", %{
    conn: conn
  } do
    user = user_fixture()
    now = DateTime.utc_now(:second)

    saved =
      free_form_session_fixture(user, %{
        completed_at: DateTime.add(now, -7 * 86_400),
        burpee_count_actual: 20,
        duration_sec_actual: 1200
      })

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    home_clock = :sys.get_state(view.pid).socket.assigns.home_snapshot_now
    route_clock = DateTime.add(now, 7 * 86_400)
    set_clock(view, route_clock)
    render_patch(view, ~p"/progress")
    assert_history_geometry(view, saved, route_clock, home_clock)

    period_clock = DateTime.add(now, 14 * 86_400)
    set_clock(view, period_clock)
    view |> element("#home-history-period-all") |> render_click()
    assert_history_geometry(view, saved, period_clock, home_clock)

    boundary_clock = DateTime.add(now, 21 * 86_400)
    set_clock(view, boundary_clock)

    :sys.replace_state(view.pid, fn state ->
      %{state | socket: Phoenix.Component.assign(state.socket, busy?: true)}
    end)

    generation = :sys.get_state(view.pid).socket.assigns.home_day_generation
    send(view.pid, {:home_day_boundary, generation})
    _ = :sys.get_state(view.pid)
    assert_history_geometry(view, saved, boundary_clock, home_clock)
    assert BurpeeTrainer.Repo.reload!(saved) == saved
    assert BurpeeTrainer.Repo.aggregate(BurpeeTrainer.Workouts.CoachRecommendation, :count) == 1
  end

  defp set_clock(view, clock) do
    :sys.replace_state(view.pid, fn state ->
      %{state | socket: Phoenix.Component.assign(state.socket, home_now: fn -> clock end)}
    end)
  end

  defp assert_history_geometry(view, saved, clock, home_clock) do
    a = :sys.get_state(view.pid).socket.assigns
    assert a.history_snapshot_now == clock
    assert a.home_snapshot_now == home_clock
    first = List.first(a.history_weeks).start |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    expected =
      DateTime.diff(saved.completed_at, first, :microsecond) /
        DateTime.diff(clock, first, :microsecond) * 100

    old_projection =
      DateTime.diff(saved.completed_at, first, :microsecond) /
        DateTime.diff(home_clock, first, :microsecond) * 100

    assert abs(expected - old_projection) > 1

    [style] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-history-point-#{saved.id}")
      |> LazyHTML.attribute("style")

    [_, left] = Regex.run(~r/left: ([0-9.]+)%/, style)
    assert_in_delta String.to_float(left), max(4.0, min(96.0, expected)), 0.000001
  end

  test "a session opens in place; Escape cancels its confirmation, then closes it, then Progress",
       %{conn: conn} do
    user = user_fixture()

    saved =
      %BurpeeTrainer.Workouts.WorkoutSession{
        user_id: user.id,
        state: :completed,
        source_kind: :manual,
        display_name_snapshot: "Saved",
        workout_type_snapshot: :six_count,
        burpee_type: :six_count,
        burpee_count_actual: 20,
        duration_sec_actual: 1200,
        completed_at: DateTime.utc_now(:second),
        capture_mode: :logged
      }
      |> BurpeeTrainer.Repo.insert!()

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/progress")
    view |> element("#home-history-density-sessions") |> render_click()
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    # It opens under its own row; nothing covers or locks the page.
    assert has_element?(view, "#home-history-session-#{saved.id} #home-history-sheet")

    refute has_element?(
             view,
             "[role=dialog], #home-history-body[inert], #home-history-close[inert]"
           )

    view |> element("#home-history-delete") |> render_click()
    view |> element("#history-page") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#home-history-delete-confirm")
    assert has_element?(view, "#home-history-sheet")
    view |> element("#history-page") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#home-history-sheet")
    assert BurpeeTrainer.Repo.reload!(saved) == saved
    view |> element("#history-page") |> render_keydown(%{"key" => "Escape"})
    assert_patch(view, "/")
    assert has_element?(view, "#home-history-toggle[phx-mounted]")
  end

  test "malformed and unrelated route events are read-only", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/progress")

    for {event, params} <- [
          {"history_period", %{}},
          {"history_period", %{"period" => "bogus"}},
          {"history_session", %{"id" => %{}}},
          {"submit_home_action", %{}}
        ] do
      render_click(view, event, params)
      assert has_element?(view, "#home-history-empty")

      assert BurpeeTrainer.Workouts.list_sessions(BurpeeTrainer.Accounts.Scope.for_user(user)) ==
               []
    end
  end

  test "authenticated History has its own route and legacy query redirects", %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/progress")
    assert has_element?(view, "#home-history-heading[tabindex='-1'][phx-mounted]")
    refute has_element?(view, "#home-state-content, #home-coach-panel")
    assert has_element?(view, "#history-page[phx-window-keydown=close_history][phx-key=Escape]")
    assert {:error, {:live_redirect, %{to: "/progress"}}} = live(conn, ~p"/?history=1")
    {:ok, legacy, _} = live(conn, ~p"/")
    pid = legacy.pid
    render_patch(legacy, ~p"/?history=1")
    assert_patch(legacy, "/progress")
    assert legacy.pid == pid
    assert has_element?(legacy, "#home-history-heading")

    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
  end
end
