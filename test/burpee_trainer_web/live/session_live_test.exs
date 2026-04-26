defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "idle state shows warmup prompt", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Grinder"})
    {:ok, _view, html} = live(conn, ~p"/session/#{plan.id}")

    assert html =~ "Grinder"
    assert html =~ "Do you want a warmup?"
    assert html =~ "Yes"
    assert html =~ "Skip"
  end

  test "mount pushes session_ready with serialized timeline", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    assert_push_event(view, "session_ready", %{timeline: timeline})
    assert is_list(timeline)
    assert length(timeline) > 0

    first = hd(timeline)
    assert Map.has_key?(first, :type)
    assert Map.has_key?(first, :duration_sec)
    assert Map.has_key?(first, :burpee_count)
    assert Map.has_key?(first, :sec_per_burpee)
    assert Map.has_key?(first, :label)
  end

  test "warmup_requested returns warmup_ready event", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "warmup_requested", %{})

    assert_push_event(view, "warmup_ready", %{warmup: warmup})
    assert is_list(warmup)
    assert length(warmup) > 0
    types = Enum.map(warmup, & &1.type)
    assert "warmup_burpee" in types
    assert "warmup_rest" in types
  end

  test "session_started transitions phase to running", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_started", %{"mood" => "0"})

    html = render(view)
    refute html =~ "Do you want a warmup?"
    refute html =~ "How do you feel?"
  end

  test "session_complete transitions to done and shows completion form", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main"   => %{"burpee_count_done" => 30, "duration_sec" => 90},
      "warmup" => %{"burpee_count_done" => 0,  "duration_sec" => 0}
    })

    html = render(view)
    assert html =~ "Session complete"
    assert has_element?(view, "form#session-completion-form")
  end

  test "session_complete pre-fills form with main counts only", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main"   => %{"burpee_count_done" => 28, "duration_sec" => 95},
      "warmup" => %{"burpee_count_done" => 5,  "duration_sec" => 60}
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
      "main"   => %{"burpee_count_done" => 30, "duration_sec" => 90},
      "warmup" => %{"burpee_count_done" => 0,  "duration_sec" => 0}
    })

    html = render(view)
    assert html =~ "Mood"
    assert html =~ "Tags"
    assert html =~ "great energy"
  end

  test "save_session creates session and navigates to history", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main"   => %{"burpee_count_done" => 28, "duration_sec" => 95},
      "warmup" => %{"burpee_count_done" => 0,  "duration_sec" => 0}
    })

    params = %{
      "burpee_type"          => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual"  => "28",
      "duration_sec_actual"  => "95",
      "note_post"            => "brutal"
    }

    {:error, {:live_redirect, %{to: "/history"}}} =
      view
      |> form("#session-completion-form", workout_session: params)
      |> render_submit()

    sessions = Workouts.list_sessions(user)
    main = Enum.find(sessions, fn s -> s.burpee_count_actual == 28 end)
    assert main
    assert main.duration_sec_actual == 95
    assert main.note_post == "brutal"
    assert main.plan_id == plan.id
  end

  test "save_session with warmup saves a separate warmup session", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main"   => %{"burpee_count_done" => 25, "duration_sec" => 80},
      "warmup" => %{"burpee_count_done" => 5,  "duration_sec" => 60}
    })

    params = %{
      "burpee_type"          => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual"  => "25",
      "duration_sec_actual"  => "80"
    }

    {:error, {:live_redirect, %{to: "/history"}}} =
      view
      |> form("#session-completion-form", workout_session: params)
      |> render_submit()

    sessions = Workouts.list_sessions(user)
    assert length(sessions) == 2

    warmup_session = Enum.find(sessions, fn s -> s.tags == "warmup" end)
    assert warmup_session
    assert warmup_session.burpee_count_actual == 5
    assert warmup_session.plan_id == nil

    main_session = Enum.find(sessions, fn s -> s.tags != "warmup" end)
    assert main_session
    assert main_session.burpee_count_actual == 25
    assert main_session.plan_id == plan.id
  end

  test "save_session with no warmup saves only main session", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    render_hook(view, "session_complete", %{
      "main"   => %{"burpee_count_done" => 30, "duration_sec" => 90},
      "warmup" => %{"burpee_count_done" => 0,  "duration_sec" => 0}
    })

    params = %{
      "burpee_type"          => "six_count",
      "burpee_count_planned" => "30",
      "duration_sec_planned" => "90",
      "burpee_count_actual"  => "30",
      "duration_sec_actual"  => "90"
    }

    {:error, {:live_redirect, %{to: "/history"}}} =
      view
      |> form("#session-completion-form", workout_session: params)
      |> render_submit()

    sessions = Workouts.list_sessions(user)
    assert length(sessions) == 1
    refute hd(sessions).tags == "warmup"
  end
end
