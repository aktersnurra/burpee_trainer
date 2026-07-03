defmodule BurpeeTrainerWeb.AppFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.PoseCaptureRun

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

  test "planned workout can be started, completed, saved, and reviewed in stats", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{"name" => "Flow Plan"})

    {:ok, home, _html} = live(conn, ~p"/")
    assert has_element?(home, "#home-start-workout[href='/session/#{plan.id}']")

    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(session, "session_complete", %{
      "main" => %{"burpee_count_done" => 28, "duration_sec" => 95},
      "warmup" => %{"burpee_count_done" => 5, "duration_sec" => 60}
    })

    assert has_element?(session, "#session-completion-form")

    session
    |> form("#session-completion-form",
      workout_session: %{
        "burpee_type" => "six_count",
        "burpee_count_planned" => "30",
        "duration_sec_planned" => "180",
        "burpee_count_actual" => "28",
        "duration_min" => "1.6",
        "note_post" => "edge-to-edge saved"
      }
    )
    |> render_submit()

    assert_redirect(session, ~p"/stats")

    [saved] = Workouts.list_sessions(user)
    assert saved.plan_id == plan.id
    assert saved.burpee_count_actual == 28
    assert saved.duration_sec_actual == 96
    assert saved.note_post == "edge-to-edge saved"
    refute saved.tags == "warmup"

    {:ok, stats, stats_html} = live(conn, ~p"/stats")
    assert stats_html =~ "Flow Plan"
    assert has_element?(stats, "#session-delete-#{saved.id}")
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

  test "tracked workout saves cadence, pose chunks, and opens analysis", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Tracked Flow"})
    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(session, "choose_tracked", %{})

    assert has_element?(
             session,
             "#pose-tracker[phx-hook='PoseTracker'][phx-update='ignore'] #pose-tracker-preview[muted][playsinline]"
           )

    assert has_element?(
             session,
             "#pose-tracker-preview-frame #pose-tracker-canvas"
           )

    assert has_element?(
             session,
             "#camera-setup-panel.pointer-events-auto #camera-setup-start-btn"
           )

    render_hook(session, "tracker_ready", %{})

    render_hook(session, "pose_capture_chunk", %{
      "segment" => "main",
      "chunk_index" => 0,
      "started_at_ms" => 0,
      "ended_at_ms" => 3_000,
      "sample_count" => 1,
      "payload" => %{"version" => 1, "samples" => [%{"tMs" => 0}]}
    })

    [run] = Repo.all(PoseCaptureRun)
    assert Repo.preload(run, :pose_trace_chunks).pose_trace_chunks != []

    render_hook(session, "finish", %{
      "reps" => 3,
      "duration_ms" => 15_000,
      "cadence_ms" => [5_000, 10_000, 15_000]
    })

    assert has_element?(session, "#session-completion-form")

    session
    |> form("#session-completion-form",
      workout_session: %{
        "burpee_type" => "six_count",
        "burpee_count_planned" => "30",
        "duration_sec_planned" => "180",
        "burpee_count_actual" => "3",
        "duration_min" => "0.25"
      }
    )
    |> render_submit()

    assert_redirect(session, ~p"/stats")

    [saved] = Workouts.list_sessions(user)
    assert saved.capture_mode == :tracked
    assert saved.cadence_ms == "[5000,10000,15000]"

    [completed_run] = Repo.all(PoseCaptureRun)
    assert completed_run.status == :completed
    assert completed_run.workout_session_id == saved.id

    {:ok, _stats, stats_html} = live(conn, ~p"/stats")
    assert stats_html =~ "Tracked"
    assert stats_html =~ ~s(href="/stats/sessions/#{saved.id}")

    {:ok, _analysis, analysis_html} = live(conn, ~p"/stats/sessions/#{saved.id}")
    assert analysis_html =~ "Session analysis"
    assert analysis_html =~ "Pace by rep"
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
end
