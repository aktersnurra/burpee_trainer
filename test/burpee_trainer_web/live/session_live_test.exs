defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders the complete client-owned session surface once", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    assert has_element?(
             view,
             "#burpee-session[phx-hook='SessionHook'][phx-update='ignore'][data-session-program][data-plan-id='#{plan.id}'][data-program-hash][data-client-session-id]"
           )

    for id <- ~w[
          session-capture-choice
          session-camera-status
          session-camera-setup
          session-warmup-choice
          session-workout-ready
          session-runner-client
          session-completion-review
          session-live-status
          session-save-errors
        ] do
      assert has_element?(view, "##{id}")
    end

    assert has_element?(view, "#pose-tracker[phx-hook='PoseTracker'][phx-update='ignore']")
    assert has_element?(view, "#session-capture-choice", "Track burpees with the camera?")
    assert has_element?(view, "#camera-choice-yes", "Yes, use camera")
    assert has_element?(view, "#camera-choice-no", "No, continue")
    refute has_element?(view, "[phx-click='session_started']")
  end

  test "renders inactive panels hidden and inert with the static completion form", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    for id <- ~w[
          session-camera-status
          session-camera-setup
          session-warmup-choice
          session-workout-ready
          session-runner-client
          session-completion-review
        ] do
      assert has_element?(view, "##{id}[hidden][inert][data-session-panel]")
    end

    assert has_element?(view, "#session-capture-choice:not([hidden])[data-session-panel]")
    assert has_element?(view, "#session-live-status[role='status'][aria-live='polite']")
    assert has_element?(view, "#session-save-errors[tabindex='-1']")

    assert has_element?(
             view,
             "#session-completion-form:not([phx-change]):not([phx-submit])"
           )

    assert has_element?(view, "#completion-reps-input")
    assert has_element?(view, "#completion-duration-input")
    assert has_element?(view, "#completion-note-input")
  end

  test "renders exact camera and hands-free prompt contract", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    assert has_element?(
             view,
             "#session-capture-choice",
             "The workout timer runs either way. Camera tracking adds a backup rep count."
           )

    assert has_element?(view, "#session-camera-status", "Starting camera")
    assert has_element?(view, "#session-camera-status", "Camera unavailable")
    assert has_element?(view, "#session-camera-status", "Nothing has started.")
    assert has_element?(view, "#camera-status-continue", "Continue without camera")
    assert has_element?(view, "#session-camera-setup", "Step into frame")
    assert has_element?(view, "#session-camera-setup", "Camera ready")
    assert has_element?(view, "#camera-setup-continue", "Continue without camera")
    assert has_element?(view, "#session-warmup-choice", "Warm up first?")
    assert has_element?(view, "#session-warmup-choice", "Raise one hand to warm up.")
    assert has_element?(view, "#session-warmup-choice", "Skipping in 4")
    assert has_element?(view, "#session-workout-ready", "Ready when you are")
    assert has_element?(view, "#session-workout-ready", "Hold one hand up to start.")
    assert has_element?(view, "#workout-ready-continue", "Continue without camera")

    refute has_element?(view, "#session-warmup-choice [data-tracked-control]")
    refute has_element?(view, "#session-workout-ready [data-tracked-control]")
    refute has_element?(view, "#burpee-session", "timer mode")
    refute has_element?(view, "#burpee-session", "Use timer")
  end

  test "server surface contains no active-session controls", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    for event <- ~w[
          choose_tracked
          fallback_to_timed
          set_mood
          toggle_tag
          validate_session
          save_session
          discard
        ] do
      refute has_element?(view, "[phx-click='#{event}']")
      refute has_element?(view, "[phx-change='#{event}']")
      refute has_element?(view, "[phx-submit='#{event}']")
    end
  end
end
