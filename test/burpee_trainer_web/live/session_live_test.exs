defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

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

  test "tracked choice renders pose tracker", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Track with camera") |> render_click()

    assert has_element?(view, "#pose-tracker[phx-hook='PoseTracker']")
  end

  test "tracked finish shows review before save", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    view |> element("button", "Track with camera") |> render_click()

    render_hook(view, "finish", %{
      "reps" => 3,
      "duration_ms" => 15_000,
      "cadence_ms" => [5_000, 10_000, 15_000]
    })

    assert render(view) =~ "Review tracked session"
    assert render(view) =~ "3 reps"
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
  end

  test "session_started transitions phase to running", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_started", %{})

    html = render(view)
    refute html =~ "Do you want a warmup?"
    refute html =~ "How do you feel?"
  end

  test "runner keeps client-owned fixed ring box and thicker progress bar", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    assert has_element?(view, "#session-runner-client[phx-update=ignore]")
    assert has_element?(view, "#ring-container.w-\\[280px\\].h-\\[280px\\]")
    assert has_element?(view, "svg#ring-svg.w-\\[280px\\].h-\\[280px\\]")
    assert has_element?(view, ".h-3 #progress-fill")
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
