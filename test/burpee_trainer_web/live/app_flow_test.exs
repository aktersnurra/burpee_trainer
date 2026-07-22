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

  test "session runner exposes the distance-safe stable runner contract", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{"name" => "Accessible Flow"})

    document =
      conn
      |> get(~p"/session/#{plan.id}")
      |> html_response(200)
      |> LazyHTML.from_document()

    [{"meta", viewport_attributes, []}] =
      document
      |> LazyHTML.query("meta[name='viewport']")
      |> LazyHTML.to_tree()

    viewport_content = Map.new(viewport_attributes)["content"]
    assert viewport_content =~ "viewport-fit=cover"
    assert viewport_content =~ "maximum-scale=1"
    assert viewport_content =~ "user-scalable=no"

    {:ok, session, _html} = live(conn, ~p"/session/#{plan.id}")
    assert_push_event(session, "session_ready", payload)

    work_event = Enum.find(payload.events, &(&1.kind == "work"))

    assert %{sec_per_rep: cadence, sec_per_burpee: active_duration} = work_event
    assert active_duration > 0
    assert active_duration <= cadence

    assert has_element?(session, "main[class*='safe-area-inset-top']")
    assert has_element?(session, "#ring-container[aria-label='Pause session']")

    assert has_element?(
             session,
             "#session-accessible-status[role='status'][aria-live='polite'][aria-atomic='true']",
             "Workout starting"
           )

    assert has_element?(session, "#ring-container #count[aria-hidden='true']")

    assert has_element?(
             session,
             "#ring-container > #set-progress[hidden][aria-hidden='true']"
           )

    refute has_element?(session, "#session-top-readout #set-progress")
    refute has_element?(session, "#count[aria-label]")
    refute has_element?(session, "#ring-container #session-accessible-status")

    for center_id <- ["ring-container", "count"],
        decoration_class <- ["border", "ring", "shadow", "outline"] do
      refute has_element?(session, "##{center_id}[class*='#{decoration_class}']")
    end

    refute has_element?(session, "#session-work-track")
    assert has_element?(session, "#session-work-fill")
    refute has_element?(session, "#session-work-threshold")
    refute has_element?(session, "#session-rest-shape")
    refute has_element?(session, "#session-work-fill[class*='scale-y-']")

    assert has_element?(
             session,
             "#session-pause-actions[inert][aria-hidden='true'].pointer-events-none"
           )

    assert has_element?(
             session,
             "#finish-early-btn[disabled].session-finish-early-action"
           )

    assert has_element?(
             session,
             "#session-abort-btn[disabled][class*='text-[var(--session-active-ink)]']"
           )

    refute has_element?(
             session,
             "#session-abort-btn[class*='text-[var(--session-active-muted)]']"
           )

    for prominent_class <- ["w-full", "border", "bg-", "rounded", "shadow", "ring"] do
      refute has_element?(session, "#session-abort-btn[class*='#{prominent_class}']")
    end

    for anchor_id <- ["session-top-readout", "ring-container", "session-pause-actions"] do
      assert has_element?(session, "#session-runner-layout > ##{anchor_id}")
    end

    assert has_element?(session, "#session-top-readout > #session-status-line")
    assert has_element?(session, "#session-status-line #total-reps[hidden]")

    assert has_element?(
             session,
             "#total-reps #total-reps-accessible.sr-only",
             "0 of #{plan.burpee_count_target} total reps"
           )

    assert has_element?(session, "#total-reps #total-done[aria-hidden='true']:not(.sr-only)", "0")

    assert has_element?(
             session,
             "#total-reps #total-plan[aria-hidden='true']:not(.sr-only)",
             Integer.to_string(plan.burpee_count_target)
           )

    assert has_element?(session, "#total-reps > span[aria-hidden='true']", "/")

    assert has_element?(
             session,
             "#session-top-readout > #session-progress[hidden][aria-hidden='true'] > #session-progress-fill"
           )

    refute has_element?(session, "#session-status-line #time-left")

    assert has_element?(
             session,
             "#session-status-line #session-time-accessible.sr-only",
             "Session time remaining"
           )

    for forbidden_label <- ["done", "left", "reps left", "sets", "phase"] do
      refute has_element?(session, "#session-status-line", forbidden_label)
    end
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

    assert has_element?(session, "#session-completion-summary")
    assert has_element?(session, "#session-completion-form")
    assert has_element?(session, "#session-save-btn.min-h-11")

    assert has_element?(
             session,
             "label[for='completion-reps-input']",
             "Reps"
           )

    assert has_element?(
             session,
             "#completion-reps-input.min-h-11[name='workout_session[burpee_count_actual]']"
           )

    assert has_element?(
             session,
             "label[for='completion-duration-min-input']",
             "Minutes"
           )

    assert has_element?(
             session,
             "#completion-duration-min-input.min-h-11[name='workout_session[duration_min]']"
           )

    assert has_element?(
             session,
             "label[for='completion-note-input']",
             "Note"
           )

    assert has_element?(
             session,
             "#completion-note-input[name='workout_session[note_post]']"
           )

    assert has_element?(session, "button[phx-click='set_mood'].min-h-14")
    assert has_element?(session, "button[phx-click='toggle_tag'].min-h-11")

    assert has_element?(
             session,
             "#session-discard-btn.min-h-11[data-confirm='Discard this session?']"
           )

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
             "#pose-tracker-visibility #pose-tracker[phx-hook='PoseTracker'][phx-update='ignore'] #pose-tracker-preview[muted][playsinline]"
           )

    assert has_element?(
             session,
             "#pose-tracker-preview-frame #pose-tracker-canvas"
           )

    assert has_element?(
             session,
             "#camera-setup-panel.pointer-events-auto #camera-setup-start-btn"
           )

    assert has_element?(session, "#camera-setup-panel #camera-setup-start-btn")
    assert has_element?(session, "#pose-tracker-preview-frame #pose-tracker-preview")
    assert has_element?(session, "#pose-tracker-preview-frame #pose-tracker-canvas")

    render_hook(session, "camera_setup_started", %{})

    refute has_element?(session, "#camera-setup-panel")

    assert has_element?(session, "#pose-tracker-visibility.invisible[aria-hidden='true']")

    assert has_element?(
             session,
             "#pose-tracker-visibility #pose-tracker[phx-hook='PoseTracker'][phx-update='ignore']"
           )

    assert has_element?(session, "#pose-tracker #pose-tracker-preview-frame")

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

    assert has_element?(session, "#tracked-review")
    assert has_element?(session, "#session-completion-summary")
    assert has_element?(session, "#session-completion-form")
    assert has_element?(session, "#session-save-btn")

    assert has_element?(
             session,
             "#session-discard-btn[data-confirm='Discard this session?']"
           )

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
