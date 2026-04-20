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

  test "start transitions to running and pushes an event_changed", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    html =
      view
      |> element("button", "Start session")
      |> render_click()

    assert html =~ "Pause"
    assert html =~ "Skip"
    assert_push_event(view, "burpee:event_changed", %{type: "work_burpee"})
  end

  test "a tick decrements remaining_sec", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()

    # First event is 10 burpees × 6.0 sec/rep = 60 sec
    assert render(view) =~ "1:00"

    _ = tick(view)
    assert render(view) =~ "0:59"
  end

  test "pause halts the timer and audio", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()
    html = view |> element("button", "Pause") |> render_click()

    assert html =~ "Resume"
    assert_push_event(view, "burpee:audio_stop", %{})
  end

  test "skip advances to the next event", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()
    assert render(view) =~ "1 / "

    view |> element("button", "Skip") |> render_click()
    assert render(view) =~ "2 / "
  end

  test "finish_early shows completion form", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()
    html = view |> element("button", "Finish early") |> render_click()

    assert html =~ "Session complete"
    assert has_element?(view, "form#session-completion-form")
  end

  test "save_session creates a session and navigates to history", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Start session") |> render_click()
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
