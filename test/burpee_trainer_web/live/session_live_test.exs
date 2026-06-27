defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.PoseCaptureRun

  defp submit_completion(view, params) do
    result =
      view
      |> form("#session-completion-form", workout_session: params)
      |> render_submit()

    if has_element?(view, "#celebration-overlay") do
      view
      |> element("#celebration-overlay button", "Continue")
      |> render_click()
    else
      result
    end
  end

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "timed mode does not render pose tracker", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    refute has_element?(view, "#pose-tracker")
  end

  test "tracked capture event creates capture run and shows camera setup gate", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "choose_tracked", %{})

    assert has_element?(view, "#pose-tracker[phx-hook='PoseTracker']")
    assert has_element?(view, "#camera-setup-panel")
    assert render(view) =~ "Adjust your camera"

    [run] = Repo.all(PoseCaptureRun)
    assert run.user_id == user.id
    assert run.plan_id == plan.id
    assert run.status == :active
  end

  test "tracker_ready marks camera setup ready", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "choose_tracked", %{})
    render_hook(view, "tracker_ready", %{})

    assert has_element?(view, "#camera-setup-panel[data-setup-state='ready']")
    assert render(view) =~ "Camera ready"
  end

  test "tracked capture chunk event persists pose trace chunk", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "choose_tracked", %{})

    render_hook(view, "pose_capture_chunk", %{
      "segment" => "warmup",
      "chunk_index" => 0,
      "started_at_ms" => 0,
      "ended_at_ms" => 3_000,
      "sample_count" => 1,
      "payload" => %{"version" => 1, "samples" => [%{"tMs" => 0}]}
    })

    [run] = Repo.all(PoseCaptureRun)
    [chunk] = Repo.preload(run, :pose_trace_chunks).pose_trace_chunks
    assert chunk.segment == :warmup
    assert chunk.chunk_index == 0
    assert chunk.sample_count == 1
    assert Jason.decode!(chunk.payload_json)["samples"] == [%{"tMs" => 0}]
  end

  test "tracked completion discard deletes uploaded pose data", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "choose_tracked", %{})

    render_hook(view, "pose_capture_chunk", %{
      "segment" => "main",
      "chunk_index" => 0,
      "started_at_ms" => 0,
      "ended_at_ms" => 3_000,
      "sample_count" => 1,
      "payload" => %{"version" => 1, "samples" => [%{"tMs" => 0}]}
    })

    [run] = Repo.all(PoseCaptureRun)
    assert Repo.preload(run, :pose_trace_chunks).pose_trace_chunks != []

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 3, "duration_sec" => 15},
      "warmup" => %{"burpee_count_done" => 0, "duration_sec" => 0}
    })

    view |> element("button[phx-click='discard']", "Discard") |> render_click()
    assert_redirect(view, ~p"/workouts")

    refute Repo.get(PoseCaptureRun, run.id)
  end

  test "tracked capture abort button deletes uploaded pose data", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "choose_tracked", %{})

    render_hook(view, "pose_capture_chunk", %{
      "segment" => "warmup",
      "chunk_index" => 0,
      "started_at_ms" => 0,
      "ended_at_ms" => 3_000,
      "sample_count" => 1,
      "payload" => %{"version" => 1, "samples" => [%{"tMs" => 0}]}
    })

    [run] = Repo.all(PoseCaptureRun)
    assert Repo.preload(run, :pose_trace_chunks).pose_trace_chunks != []

    view |> element("#session-abort-btn") |> render_click()
    assert_redirect(view, ~p"/workouts")

    refute Repo.get(PoseCaptureRun, run.id)
  end

  test "tracked capture abort event deletes uploaded pose data", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "choose_tracked", %{})

    render_hook(view, "pose_capture_chunk", %{
      "segment" => "warmup",
      "chunk_index" => 0,
      "started_at_ms" => 0,
      "ended_at_ms" => 3_000,
      "sample_count" => 1,
      "payload" => %{"version" => 1, "samples" => [%{"tMs" => 0}]}
    })

    [run] = Repo.all(PoseCaptureRun)
    assert Repo.preload(run, :pose_trace_chunks).pose_trace_chunks != []

    render_hook(view, "pose_capture_abort", %{"reason" => "user_discarded"})

    refute Repo.get(PoseCaptureRun, run.id)
  end

  test "timed mode keeps pose tracker absent after normal session completion", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 10, "duration_sec" => 60},
      "warmup" => %{"burpee_count_done" => 0, "duration_sec" => 0}
    })

    refute has_element?(view, "#pose-tracker")
  end

  test "tracked finish shows review before save", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "choose_tracked", %{})

    render_hook(view, "finish", %{
      "reps" => 3,
      "duration_ms" => 15_000,
      "cadence_ms" => [5_000, 10_000, 15_000]
    })

    assert render(view) =~ "Review tracked session"
    assert render(view) =~ "3 reps"
    assert has_element?(view, "form#session-completion-form")
  end

  test "tracked finish saves cadence trace", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "choose_tracked", %{})

    render_hook(view, "finish", %{
      "reps" => 3,
      "duration_ms" => 15_000,
      "cadence_ms" => [5_000, 10_000, 15_000]
    })

    params = %{
      "burpee_type" => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual" => "3",
      "duration_min" => "0.25"
    }

    {:error, {:live_redirect, %{to: "/stats"}}} = submit_completion(view, params)

    [session] = Workouts.list_sessions(user)
    assert session.capture_mode == :tracked
    assert session.cadence_ms == "[5000,10000,15000]"

    [run] = Repo.all(PoseCaptureRun)
    assert run.status == :completed
    assert run.workout_session_id == session.id
  end

  test "idle state shows warmup prompt", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Grinder"})
    {:ok, _view, html} = live(conn, ~p"/session/#{plan.id}")

    assert html =~ "Warmup?"
    assert html =~ "Yes"
    assert html =~ "Skip"
  end

  test "mount pushes session_ready with serialized plan", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    assert_push_event(view, "session_ready", %{plan: plan_payload})
    assert is_list(plan_payload.blocks)
    assert length(plan_payload.blocks) > 0

    first_block = hd(plan_payload.blocks)
    first_set = hd(first_block.sets)
    assert Map.has_key?(first_block, :repeat_count)
    assert Map.has_key?(first_set, :burpee_count)
    assert Map.has_key?(first_set, :sec_per_rep)
    assert Map.has_key?(first_set, :end_of_set_rest)
    assert is_list(plan_payload.timeline)
  end

  test "session_ready timeline includes additional rests as first-class events", %{
    conn: conn,
    user: user
  } do
    sets =
      for position <- 1..40 do
        %{
          "position" => position,
          "burpee_count" => 5,
          "sec_per_rep" => 6.0,
          "sec_per_burpee" => 3.0,
          "end_of_set_rest" => 0
        }
      end

    plan =
      plan_fixture(user, %{
        "name" => "Session Rest Plan",
        "additional_rests" => Jason.encode!([%{"target_min" => 18, "rest_sec" => 10}]),
        "blocks" => [%{"position" => 1, "repeat_count" => 1, "sets" => sets}]
      })

    {:ok, view, html} = live(conn, ~p"/session/#{plan.id}")

    assert html =~ "20:10"
    assert_push_event(view, "session_ready", %{plan: plan_payload})

    assert Enum.count(plan_payload.timeline, &(&1.phase == "rest")) == 1

    rest_index = Enum.find_index(plan_payload.timeline, &(&1.phase == "rest"))
    assert rest_index == 36
    assert Enum.at(plan_payload.timeline, rest_index).duration_sec == 10

    {before_rest, [_rest | after_rest]} = Enum.split(plan_payload.timeline, rest_index)
    assert Enum.sum(Enum.map(before_rest, &(&1.burpee_count || 0))) == 180
    assert Enum.sum(Enum.map(after_rest, &(&1.burpee_count || 0))) == 20
    assert Enum.sum(Enum.map(plan_payload.timeline, & &1.duration_sec)) == 1210
  end

  test "session_started transitions phase to running", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_started", %{})

    html = render(view)
    refute html =~ "Do you want a warmup?"
    refute html =~ "How do you feel?"
  end

  test "runner renders quiet stone instrument shell", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    assert has_element?(view, "#burpee-session.session-surface")
    assert has_element?(view, "#session-runner-client[phx-update=ignore]")
    assert has_element?(view, "#ring-container[aria-label='Pause or resume session']")
    assert has_element?(view, "svg#ring-svg")
    assert has_element?(view, "#set-glyphs[aria-label='Workout sets']")
    assert has_element?(view, "#session-status-line")
    assert has_element?(view, "#session-pause-actions[aria-hidden=true]")
    refute has_element?(view, "#resume-session-btn")
    assert has_element?(view, "#session-abort-btn")
    assert has_element?(view, "#finish-early-btn")
    refute has_element?(view, "#session-progress-card")
    refute has_element?(view, "#session-progress-fill")
    assert has_element?(view, "#total-done")
    assert has_element?(view, "#total-plan")
    assert has_element?(view, "#time-left")

    html = render(view)
    refute html =~ "Back to workouts"
    refute html =~ "Progress"
    refute html =~ "REPS LEFT"
    refute html =~ "RUNNING"
    refute html =~ "BEAT"
    refute html =~ "BLOCKS"
  end

  test "session_complete transitions to done and shows completion form", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 30, "duration_sec" => 90},
      "warmup" => %{"burpee_count_done" => 0, "duration_sec" => 0}
    })

    html = render(view)
    assert html =~ "Session complete"
    assert has_element?(view, "form#session-completion-form")
  end

  test "session_complete pre-fills form with main counts only", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 28, "duration_sec" => 95},
      "warmup" => %{"burpee_count_done" => 5, "duration_sec" => 60}
    })

    html = render(view)
    # Completion form should show main counts, not warmup + main
    assert html =~ "28"
    assert html =~ "95"
  end

  test "completion form shows mood and tag options", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 30, "duration_sec" => 90},
      "warmup" => %{"burpee_count_done" => 0, "duration_sec" => 0}
    })

    html = render(view)
    assert html =~ "Tired"
  end

  test "session_complete rejects negative counts", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => -1, "duration_sec" => 90},
      "warmup" => %{"burpee_count_done" => 0, "duration_sec" => 0}
    })

    html = render(view)
    refute html =~ "Session complete"
    refute has_element?(view, "form#session-completion-form")
    assert html =~ "Invalid session result"
  end

  test "session_complete rejects non-numeric durations", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 30, "duration_sec" => "fast"},
      "warmup" => %{"burpee_count_done" => 0, "duration_sec" => 0}
    })

    html = render(view)
    refute html =~ "Session complete"
    refute has_element?(view, "form#session-completion-form")
    assert html =~ "Invalid session result"
  end

  test "save_session creates session and navigates to history", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 28, "duration_sec" => 95},
      "warmup" => %{"burpee_count_done" => 0, "duration_sec" => 0}
    })

    params = %{
      "burpee_type" => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual" => "28",
      "duration_min" => "1.6",
      "note_post" => "brutal"
    }

    {:error, {:live_redirect, %{to: "/stats"}}} = submit_completion(view, params)

    sessions = Workouts.list_sessions(user)
    main = Enum.find(sessions, fn s -> s.burpee_count_actual == 28 end)
    assert main
    assert main.duration_sec_actual == round(1.6 * 60)
    assert main.note_post == "brutal"
    assert main.plan_id == plan.id
  end

  test "save_session with warmup saves only the main workout session", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 25, "duration_sec" => 80},
      "warmup" => %{"burpee_count_done" => 5, "duration_sec" => 60}
    })

    params = %{
      "burpee_type" => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual" => "25",
      "duration_min" => "1.34"
    }

    {:error, {:live_redirect, %{to: "/stats"}}} = submit_completion(view, params)

    [main_session] = Workouts.list_sessions(user)
    assert main_session.burpee_count_actual == 25
    assert main_session.plan_id == plan.id
    refute main_session.tags == "warmup"
  end

  test "save_session with no warmup saves only main session", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 30, "duration_sec" => 90},
      "warmup" => %{"burpee_count_done" => 0, "duration_sec" => 0}
    })

    params = %{
      "burpee_type" => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual" => "30",
      "duration_min" => "1.5"
    }

    {:error, {:live_redirect, %{to: "/stats"}}} = submit_completion(view, params)

    sessions = Workouts.list_sessions(user)
    assert length(sessions) == 1
    refute hd(sessions).tags == "warmup"
  end

  test "save_session does not persist warmup when main session is invalid", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main" => %{"burpee_count_done" => 25, "duration_sec" => 80},
      "warmup" => %{"burpee_count_done" => 5, "duration_sec" => 60}
    })

    params = %{
      "burpee_type" => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual" => "",
      "duration_min" => ""
    }

    view
    |> form("#session-completion-form", workout_session: params)
    |> render_submit()

    assert Workouts.list_sessions(user) == []
  end
end
