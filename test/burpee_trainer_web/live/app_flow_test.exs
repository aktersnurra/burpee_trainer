defmodule BurpeeTrainerWeb.AppFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainerWeb.SessionLive

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "new workout can be generated, saved, and started from home", %{conn: conn, user: user} do
    {:ok, creator, _html} = live(conn, ~p"/workouts/new")

    render_change(creator, "change_basics", %{
      "target_duration_min" => "20",
      "burpee_count_target" => "144"
    })

    render_click(creator, "pick_pacing", %{"style" => "unbroken"})
    render_change(creator, "change_basics", %{"reps_per_set" => "8"})
    creator |> element("#generate-workout") |> render_click()
    creator |> element("#edit-workout") |> render_click()

    assert has_element?(creator, "#workout-editor-overview")
    creator |> element("#plan-form") |> render_submit(%{"workout_plan" => %{}})
    assert_redirect(creator, ~p"/workouts")

    [created] = Workouts.list_plans(user)
    assert created.burpee_count_target == 144
    assert created.target_duration_min == 20

    {:ok, home, _html} = live(conn, ~p"/")
    assert has_element?(home, "#home-start-workout[href='/session/#{created.id}']")
  end

  test "session renders the stable client-owned runner contract", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Accessible Flow"})
    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")

    assert has_element?(
             session,
             "#burpee-session[phx-hook='SessionHook'][phx-update='ignore'][data-plan-id='#{plan.id}'][data-program-hash][data-client-session-id]"
           )

    for id <- [
          "session-capture-choice",
          "session-camera-status",
          "session-camera-setup",
          "session-warmup-choice",
          "session-workout-ready",
          "session-runner-client",
          "session-completion-review"
        ] do
      assert has_element?(session, "##{id}[data-session-panel]")
    end

    assert has_element?(session, "#ring-container[aria-label='Pause session']")
    assert has_element?(session, "#session-work-fill")
    assert has_element?(session, "#session-pause-actions[inert][aria-hidden='true']")
    assert has_element?(session, "#finish-early-btn[disabled].session-finish-early-action")

    assert has_element?(
             session,
             "#session-abort-btn[disabled][class*='text-[var(--session-active-ink)]']"
           )

    refute has_element?(session, "[phx-click='choose_tracked']")
    refute has_element?(session, "[phx-click='fallback_to_timed']")
    refute has_element?(session, "#session-completion-form[phx-submit]")
  end

  test "Save returns structured success, validation, replay, and conflict replies", %{user: user} do
    plan = plan_fixture(user, %{"name" => "Reply Flow"})
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
             SessionLive.handle_event(
               "begin_session",
               %{"client_session_id" => client_session_id},
               socket
             )

    assert {:reply,
            %{
              status: "invalid",
              field_errors: %{"burpee_count_actual" => ["must be greater than or equal to 0"]},
              global_errors: []
            }, ^socket} =
             SessionLive.handle_event(
               "save_session",
               save_payload(client_session_id, %{
                 "burpee_count_actual" => -1,
                 "duration_sec_actual" => 60
               }),
               socket
             )

    payload =
      save_payload(client_session_id, %{
        "burpee_count_actual" => 20,
        "duration_sec_actual" => 60
      })

    assert {:reply,
            %{
              status: "ok",
              session_id: ^session_id,
              lifecycle_status: "reported",
              report_status: "reported",
              redirect_to: "/stats"
            }, ^socket} =
             SessionLive.handle_event("save_session", payload, socket)

    assert {:reply, %{status: "ok", report_status: "existing"}, ^socket} =
             SessionLive.handle_event("save_session", payload, socket)

    assert {:reply, %{status: "error", reason: "report_conflict"}, ^socket} =
             SessionLive.handle_event(
               "save_session",
               save_payload(client_session_id, %{
                 "burpee_count_actual" => 99,
                 "duration_sec_actual" => 99
               }),
               socket
             )

    assert Workouts.get_session!(user, session_id).client_session_id == client_session_id
  end

  test "no-camera Save persists timer-authoritative session", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Timer Flow"})
    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")
    client_session_id = begin_session(session, user)

    render_hook(
      session,
      "save_session",
      save_payload(client_session_id, %{
        "burpee_count_actual" => 28,
        "duration_sec_actual" => 95,
        "note_post" => "edge-to-edge saved"
      })
    )

    [saved] = Workouts.list_sessions(user)
    assert saved.plan_id == plan.id
    assert saved.client_session_id == client_session_id
    assert saved.capture_mode == :timed
    assert saved.burpee_count_actual == 28
    assert saved.duration_sec_actual == 95
    assert saved.note_post == "edge-to-edge saved"
    assert saved.cadence_ms == nil
  end

  test "trusted unchanged camera Save persists validated cadence", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Tracked Flow"})
    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")
    client_session_id = begin_session(session, user)

    render_hook(
      session,
      "save_session",
      save_payload(
        client_session_id,
        %{"burpee_count_actual" => 3, "duration_sec_actual" => 15},
        %{
          "enabled" => true,
          "trust" => "finished",
          "detected_reps" => 3,
          "detected_duration_sec" => 15,
          "cadence_ms" => [5_000, 10_000, 15_000]
        }
      )
    )

    [saved] = Workouts.list_sessions(user)
    assert saved.capture_mode == :tracked
    assert saved.burpee_count_actual == 3
    assert saved.duration_sec_actual == 15
    assert saved.cadence_ms == "[5000,10000,15000]"
    assert saved.target_pace_sec
    assert saved.pace_consistency == 1.0
  end

  test "corrected camera Save stays tracked without cadence analytics", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Edited Tracked Flow"})
    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")
    client_session_id = begin_session(session, user)

    render_hook(
      session,
      "save_session",
      save_payload(
        client_session_id,
        %{"burpee_count_actual" => 4, "duration_sec_actual" => 15},
        %{
          "enabled" => true,
          "trust" => "finished",
          "detected_reps" => 3,
          "detected_duration_sec" => 15,
          "cadence_ms" => [5_000, 10_000, 15_000]
        }
      )
    )

    [saved] = Workouts.list_sessions(user)
    assert saved.capture_mode == :tracked
    assert saved.burpee_count_actual == 4
    assert saved.cadence_ms == nil
    assert saved.target_pace_sec == nil
    assert saved.pace_consistency == nil
  end

  test "degraded camera Save uses ordinary timer persistence", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Degraded Tracking Flow"})
    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")
    client_session_id = begin_session(session, user)

    render_hook(
      session,
      "save_session",
      save_payload(
        client_session_id,
        %{"burpee_count_actual" => 12, "duration_sec_actual" => 75},
        %{
          "enabled" => true,
          "trust" => "degraded",
          "reason" => "detector_error",
          "detected_reps" => 99,
          "detected_duration_sec" => 5,
          "cadence_ms" => [1_000]
        }
      )
    )

    [saved] = Workouts.list_sessions(user)
    assert saved.capture_mode == :timed
    assert saved.burpee_count_actual == 12
    assert saved.duration_sec_actual == 75
    assert saved.cadence_ms == nil
  end

  test "invalid Save leaves the lifecycle session unreported for client correction", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{"name" => "Invalid Flow"})
    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")
    client_session_id = begin_session(session, user)

    render_hook(
      session,
      "save_session",
      save_payload(client_session_id, %{
        "burpee_count_actual" => -1,
        "duration_sec_actual" => 10
      })
    )

    assert %{client_session_id: ^client_session_id, status: :running} =
             Workouts.get_unresolved_session(user)

    assert has_element?(session, "#session-completion-form")
  end

  test "repeated client session id replays the existing saved session", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Idempotent Flow"})
    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")
    client_session_id = begin_session(session, user)

    payload =
      save_payload(client_session_id, %{
        "burpee_count_actual" => 10,
        "duration_sec_actual" => 60
      })

    render_hook(session, "save_session", payload)
    render_hook(session, "save_session", payload)

    assert [saved] = Workouts.list_sessions(user)
    assert saved.client_session_id == client_session_id
    assert saved.burpee_count_actual == 10
    assert saved.duration_sec_actual == 60
  end

  test "home log past session saves manual work and refreshes history", %{conn: conn, user: user} do
    {:ok, home, _html} = live(conn, ~p"/")

    home |> element("#home-log-session") |> render_click()
    assert has_element?(home, "#home-log-modal")

    home
    |> form("#log-form-home-log-form",
      workout_session: %{
        "burpee_count_actual" => "41",
        "duration_sec_actual" => "7",
        "log_date" => Date.utc_today() |> Date.to_iso8601()
      }
    )
    |> render_submit()

    refute has_element?(home, "#home-log-modal")

    [logged] = Workouts.list_sessions(user)
    assert logged.plan_id == nil
    assert logged.capture_mode == :logged
    assert logged.burpee_type == :six_count
    assert logged.burpee_count_actual == 41
    assert logged.duration_sec_actual == 7 * 60

    {:ok, stats, _stats_html} = live(conn, ~p"/stats")
    assert has_element?(stats, "#stats-pushups-all-time", "41")
    assert has_element?(stats, "#session-delete-#{logged.id}")
  end

  test "stats deletion removes a saved session from history and home totals", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{"name" => "Delete Flow"})
    saved = session_from_plan_fixture(user, plan, %{"duration_sec_actual" => "600"})

    {:ok, stats, _html} = live(conn, ~p"/stats")
    assert has_element?(stats, "#session-delete-#{saved.id}")

    stats |> element("#session-delete-#{saved.id}") |> render_click()

    refute has_element?(stats, "#session-delete-#{saved.id}")
    assert Workouts.list_sessions(user) == []

    {:ok, home, _html} = live(conn, ~p"/")
    assert has_element?(home, "#home-week-progress[aria-valuenow='0']")
  end

  defp begin_session(view, user) do
    client_session_id = mounted_client_session_id(view)

    render_hook(view, "begin_session", %{"client_session_id" => client_session_id})

    assert %{client_session_id: ^client_session_id, status: :running} =
             Workouts.get_unresolved_session(user)

    client_session_id
  end

  defp mounted_client_session_id(view) do
    document = view |> render() |> LazyHTML.from_fragment()
    session = LazyHTML.query(document, "#burpee-session")
    [client_session_id] = LazyHTML.attribute(session, "data-client-session-id")
    client_session_id
  end

  defp save_payload(client_session_id, session_attrs, tracking \\ %{"enabled" => false}) do
    %{
      "workout_session" =>
        Map.merge(
          %{
            "burpee_type" => "six_count",
            "burpee_count_actual" => 30,
            "burpee_count_planned" => 30,
            "duration_sec_actual" => 120,
            "duration_sec_planned" => 1_200,
            "client_session_id" => client_session_id,
            "mood" => 0,
            "tags" => "",
            "note_post" => ""
          },
          session_attrs
        ),
      "tracking" => tracking
    }
  end
end
