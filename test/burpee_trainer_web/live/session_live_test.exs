defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  defp tick(view), do: send(view.pid, :tick) |> then(fn _ -> render(view) end)

  test "idle state shows Start button and totals", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Grinder"})
    {:ok, _view, html} = live(conn, ~p"/session/#{plan.id}")

    assert html =~ "Grinder"
    assert html =~ "Start session"
    assert html =~ "30"
  end

  test "start enters preroll and pushes a countdown cue", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    html =
      view
      |> element("button", "Start session")
      |> render_click()

    assert html =~ "Get ready"
    assert_push_event(view, "burpee:event_changed", %{type: "countdown", remaining_sec: 5})
  end

  test "preroll ticks down and then transitions to running", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()
    assert render(view) =~ "Get ready"

    _ = tick(view)
    assert render(view) =~ "Get ready"

    # Drain the remaining 4 preroll ticks; the 5th tick transitions to running.
    Enum.each(1..4, fn _ -> tick(view) end)

    html = render(view)
    assert html =~ "Pause"
    # First work event is 10 burpees × 6.0 sec/rep = 60s
    assert html =~ "1:00"
    assert_push_event(view, "burpee:event_changed", %{type: "work_burpee"})
  end

  test "pause halts the timer and audio", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()
    # Advance past preroll
    Enum.each(1..5, fn _ -> tick(view) end)

    html = view |> element("button", "Pause") |> render_click()

    assert html =~ "Resume"
    assert_push_event(view, "burpee:audio_stop", %{})
  end

  test "finish_early shows completion form", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()
    Enum.each(1..5, fn _ -> tick(view) end)
    html = view |> element("button", "Finish early") |> render_click()

    assert html =~ "Session complete"
    assert has_element?(view, "form#session-completion-form")
  end

  test "save_session creates a session and navigates to history", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()
    Enum.each(1..5, fn _ -> tick(view) end)
    view |> element("button", "Finish early") |> render_click()

    params = %{
      "burpee_type" => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual" => "28",
      "duration_sec_actual" => "95",
      "note_post" => "brutal"
    }

    {:error, {:live_redirect, %{to: "/history"}}} =
      view
      |> form("#session-completion-form", workout_session: params)
      |> render_submit()

    assert [session] = Workouts.list_sessions(user)
    assert session.burpee_count_actual == 28
    assert session.duration_sec_actual == 95
    assert session.note_post == "brutal"
    assert session.plan_id == plan.id
  end
end
