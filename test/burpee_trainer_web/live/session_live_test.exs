defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders the complete client-owned session surface once", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")
    {:ok, program} = Workouts.compile_plan(plan)
    document = view |> render() |> LazyHTML.from_fragment()

    stable_ids =
      ~w[
        burpee-session
        session-capture-choice
        session-camera-status
        session-camera-setup
        session-warmup-choice
        session-workout-ready
        session-runner-client
        session-completion-review
        pose-tracker
        camera-choice-yes
        camera-choice-no
        camera-status-retry
        camera-status-continue
        camera-setup-continue
        warmup-yes-btn
        warmup-skip-btn
        workout-ready-btn
        workout-ready-continue
        ring-container
        finish-early-btn
        session-abort-btn
        session-completion-form
        completion-reps-input
        completion-duration-input
        completion-note-input
        session-save-btn
        session-discard-btn
        session-live-status
        session-save-errors
        session-report-pending-status
        session-report-pending-retry
        completion-reps-error
        completion-duration-error
        completion-note-error
      ]

    for id <- stable_ids do
      assert has_element?(view, "##{id}")
      assert selector_count(document, "##{id}") == 1
    end

    assert has_element?(
             view,
             "#burpee-session[phx-hook='SessionHook'][phx-update='ignore'][data-session-program][data-plan-id][data-program-hash][data-client-session-id]"
           )

    session = LazyHTML.query(document, "#burpee-session")
    [serialized_program] = LazyHTML.attribute(session, "data-session-program")
    [plan_id] = LazyHTML.attribute(session, "data-plan-id")
    [program_hash] = LazyHTML.attribute(session, "data-program-hash")
    [client_session_id] = LazyHTML.attribute(session, "data-client-session-id")
    decoded_program = Jason.decode!(serialized_program)

    assert plan_id == Integer.to_string(plan.id)
    assert program_hash == program.content_hash
    assert decoded_program["program_id"] == program.id
    assert decoded_program["program_hash"] == program_hash
    assert decoded_program["target_reps"] == program.target_reps
    assert decoded_program["target_duration_sec"] == program.target_duration_sec
    assert is_list(decoded_program["events"])
    assert is_map(decoded_program["display"])
    assert Ecto.UUID.cast(client_session_id) == {:ok, client_session_id}

    assert has_element?(view, "#pose-tracker[phx-hook='PoseTracker'][phx-update='ignore']")
    assert has_element?(view, "#session-capture-choice", "Track burpees with the camera?")
    assert has_element?(view, "#camera-choice-yes", "Yes, use camera")
    assert has_element?(view, "#camera-choice-no", "No, continue")

    assert selector_count(
             document,
             ".session-choice-toggle[data-mood][aria-pressed='false']"
           ) == 3

    assert selector_count(
             document,
             ".session-choice-toggle[data-tag][aria-pressed='false']"
           ) == 6

    refute has_element?(view, "[phx-click='session_started']")
    refute has_element?(view, "nav")
    refute has_element?(view, "#flash-group")
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
    assert has_element?(view, "#session-report-pending-status[role='status'][hidden][inert]")
    assert has_element?(view, "#session-report-pending-retry[hidden][inert]")

    for heading_id <- ~w[
          session-capture-choice-heading
          camera-status-heading
          camera-setup-heading
          session-warmup-heading
          session-workout-ready-heading
          session-runner-heading
          session-completion-heading
        ] do
      assert has_element?(view, "##{heading_id}[data-session-heading][tabindex='-1']")
    end

    assert has_element?(
             view,
             "#session-completion-form:not([phx-change]):not([phx-submit])"
           )

    assert has_element?(
             view,
             "#session-completion-review > div.h-dvh.overflow-y-auto"
           )

    refute has_element?(
             view,
             "#session-completion-review > div.min-h-dvh.overflow-y-auto"
           )

    assert has_element?(view, "#completion-reps-input")
    assert has_element?(view, "#completion-duration-input")
    assert has_element?(view, "#completion-note-input")
  end

  test "pre-renders empty completion field errors and associates each input once", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")
    document = view |> render() |> LazyHTML.from_fragment()

    for field <- ~w[reps duration note] do
      input_selector =
        "#completion-#{field}-input[aria-describedby='completion-#{field}-error']"

      error_selector = "#completion-#{field}-error[hidden]"

      assert has_element?(view, input_selector)
      assert has_element?(view, error_selector)
      assert selector_count(document, input_selector) == 1
      assert selector_count(document, error_selector) == 1
      assert document |> LazyHTML.query(error_selector) |> LazyHTML.text() == ""
    end
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

  test "redirects an unresolved lifecycle before booting another runner", %{
    conn: conn,
    user: user
  } do
    running_plan = plan_fixture(user)

    assert {:ok, lifecycle} =
             Workouts.begin_plan_session(user, running_plan, Ecto.UUID.generate())

    next_plan = plan_fixture(user)

    expected_path = "/sessions/#{lifecycle.id}/resolve"

    assert {:error, {:live_redirect, %{to: ^expected_path}}} =
             live(conn, ~p"/session/#{next_plan.id}")
  end

  test "concurrent begin returns a retry-safe unresolved session reply", %{user: user} do
    running_plan = plan_fixture(user)

    assert {:ok, unresolved} =
             Workouts.begin_plan_session(user, running_plan, Ecto.UUID.generate())

    plan = plan_fixture(user)
    client_session_id = Ecto.UUID.generate()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        current_user: user,
        plan: plan,
        client_session_id: client_session_id,
        target_pace_sec: 5.0
      }
    }

    assert {:reply,
            %{
              status: "error",
              reason: "unresolved_session",
              retryable: true,
              session_id: unresolved_id,
              resolve_to: resolve_to
            }, ^socket} =
             BurpeeTrainerWeb.SessionLive.handle_event(
               "begin_session",
               %{"client_session_id" => client_session_id},
               socket
             )

    assert unresolved_id == unresolved.id
    assert resolve_to == "/sessions/#{unresolved.id}/resolve"
  end

  test "lifecycle hook events use the mounted UUID and report the existing row", %{user: user} do
    plan = plan_fixture(user)
    client_session_id = Ecto.UUID.generate()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        current_user: user,
        plan: plan,
        client_session_id: client_session_id,
        target_pace_sec: 5.0
      }
    }

    assert {:reply,
            %{
              status: "ok",
              client_session_id: ^client_session_id,
              session_id: session_id,
              lifecycle_status: "running"
            }, ^socket} =
             BurpeeTrainerWeb.SessionLive.handle_event(
               "begin_session",
               %{"client_session_id" => client_session_id},
               socket
             )

    assert {:reply, %{status: "ok", lifecycle_status: "report_pending"}, ^socket} =
             BurpeeTrainerWeb.SessionLive.handle_event(
               "mark_report_pending",
               %{"client_session_id" => client_session_id},
               socket
             )

    attrs = %{
      "client_session_id" => client_session_id,
      "burpee_type" => "six_count",
      "burpee_count_actual" => 4,
      "duration_sec_actual" => 20,
      "mood" => 0,
      "tags" => "",
      "note_post" => ""
    }

    assert {:reply, %{status: "ok", session_id: ^session_id, lifecycle_status: "reported"},
            ^socket} =
             BurpeeTrainerWeb.SessionLive.handle_event(
               "save_session",
               %{"workout_session" => attrs, "tracking" => %{}},
               socket
             )

    assert [%{id: ^session_id}] = Workouts.list_sessions(user)

    assert {:reply, %{status: "error", reason: "not_found"}, ^socket} =
             BurpeeTrainerWeb.SessionLive.handle_event(
               "save_session",
               %{
                 "workout_session" => Map.put(attrs, "client_session_id", Ecto.UUID.generate()),
                 "tracking" => %{}
               },
               socket
             )
  end

  defp selector_count(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
    |> length()
  end
end
