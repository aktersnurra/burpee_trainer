defmodule BurpeeTrainerWeb.HistoryWorkspaceTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  test "route and busy boundary chart geometry use History's distinct genuine clock", %{
    conn: conn
  } do
    user = user_fixture()
    now = DateTime.utc_now(:second)
    # Mid-week last week: a session right at the start of the chart's first week sits at
    # 0% under every clock, and the projections below could not tell the clocks apart.
    last_week = now |> DateTime.to_date() |> Date.add(-7) |> Date.beginning_of_week()

    saved =
      free_form_session_fixture(user, %{
        completed_at: DateTime.new!(Date.add(last_week, 3), ~T[12:00:00], "Etc/UTC"),
        burpee_count_actual: 20,
        duration_sec_actual: 1200
      })

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    home_clock = :sys.get_state(view.pid).socket.assigns.home_snapshot_now
    route_clock = DateTime.add(now, 7 * 86_400)
    set_clock(view, route_clock)
    render_patch(view, ~p"/progress")
    assert_history_geometry(view, saved, route_clock, home_clock)

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

  test "Escape lets go of an armed trash, then of the session, then leaves Progress",
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
    view |> element("#home-history-point-#{saved.id}") |> render_click()
    trash = "#home-history-delete-#{saved.id}"
    # Its trash shows in its row; nothing covers or locks the page.
    assert has_element?(view, trash)

    refute has_element?(
             view,
             "[role=dialog], #home-history-body[inert], #home-history-close[inert]"
           )

    view |> element(trash) |> render_click()
    view |> element("#history-page") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#{trash}.home-history-session-delete-armed")
    assert has_element?(view, trash)
    view |> element("#history-page") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, trash)
    assert BurpeeTrainer.Repo.reload!(saved) == saved
    view |> element("#history-page") |> render_keydown(%{"key" => "Escape"})
    assert_patch(view, "/")
    assert has_element?(view, "#home-history-toggle[phx-mounted]")
  end

  test "malformed and unrelated route events are read-only", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/progress")

    for {event, params} <- [
          {"history_session", %{}},
          {"history_session", %{"id" => "bogus"}},
          {"history_session", %{"id" => %{}}}
        ] do
      render_click(view, event, params)
      assert has_element?(view, "#home-history-empty")

      assert BurpeeTrainer.Workouts.list_sessions(BurpeeTrainer.Accounts.Scope.for_user(user)) ==
               []
    end
  end
end
