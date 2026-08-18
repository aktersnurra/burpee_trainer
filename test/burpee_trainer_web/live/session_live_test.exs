defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "mount and reconnect load one exact started session without inserting", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    assert {:ok, session} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
    assert Repo.aggregate(WorkoutSession, :count) == 1

    assert {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 1

    assert has_element?(
             view,
             "#burpee-session[data-session-id='#{session.id}'][data-source-kind='plan'][data-content-hash='#{session.content_hash}'][data-client-session-id='#{session.client_session_id}']"
           )

    [serialized] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#burpee-session")
      |> LazyHTML.attribute("data-session-program")

    payload = Jason.decode!(serialized)
    assert payload["program_hash"] == session.content_hash
    assert payload["target_reps"] == session.burpee_count_planned
    assert payload["target_duration_sec"] == session.duration_sec_planned
    assert is_list(payload["events"])

    assert {:ok, _reconnected, _html} = live(conn, ~p"/session/#{session.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "a started snapshot remains executable after its plan is archived", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    assert {:ok, session} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
    snapshot = session.program_snapshot
    assert {:ok, _archived} = Workouts.archive_plan(user, plan.id)

    assert {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

    [serialized] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#burpee-session")
      |> LazyHTML.attribute("data-session-program")

    assert Jason.decode!(serialized)["events"] == runner_events(snapshot)
  end

  test "save_session updates the mounted row once and retains capture and feedback", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
    assert {:ok, view, _html} = live(conn, ~p"/session/#{started.id}")

    _html =
      render_hook(view, "save_session", %{
        "workout_session" => %{
          "burpee_count_actual" => 4,
          "duration_sec_actual" => 20,
          "context_low_energy" => false,
          "context_high_energy" => true,
          "context_heat_affected" => false,
          "primary_limiter" => "legs",
          "preference_feedback" => "avoid",
          "note_post" => "Exact row"
        },
        "tracking" => %{
          "enabled" => true,
          "trust" => "finished",
          "detected_reps" => 4,
          "detected_duration_sec" => 20,
          "cadence_ms" => [5_000, 10_000, 15_000, 20_000]
        }
      })

    assert Repo.aggregate(WorkoutSession, :count) == 1

    completed = Repo.get!(WorkoutSession, started.id)
    assert completed.state == :completed
    assert completed.capture_mode == :tracked
    assert completed.context_high_energy
    assert completed.primary_limiter == :legs
    assert completed.preference_feedback == :avoid

    _html =
      render_hook(view, "save_session", %{
        "workout_session" => %{
          "burpee_count_actual" => 99,
          "duration_sec_actual" => 99
        },
        "tracking" => %{"enabled" => false}
      })

    assert Repo.aggregate(WorkoutSession, :count) == 1
    assert Repo.get!(WorkoutSession, started.id) == completed
  end

  test "forged completion and capture values return validation without completing", %{
    conn: conn,
    user: user
  } do
    valid_attrs = %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 4,
      "burpee_count_planned" => 5,
      "duration_sec_actual" => 20,
      "duration_sec_planned" => 25,
      "client_session_id" => Ecto.UUID.generate(),
      "mood" => 1,
      "tags" => "great_energy",
      "context_low_energy" => false,
      "context_high_energy" => false,
      "context_heat_affected" => false,
      "primary_limiter" => "legs",
      "preference_feedback" => "avoid",
      "note_post" => "Exact row"
    }

    valid_tracking = %{
      "enabled" => true,
      "trust" => "finished",
      "reason" => nil,
      "detected_reps" => 4,
      "detected_duration_sec" => 20,
      "cadence_ms" => [5_000, 10_000, 15_000, 20_000]
    }

    forged_payloads = [
      {"workout_session", "burpee_count_actual", %{}},
      {"workout_session", "duration_sec_actual", []},
      {"workout_session", "note_post", 123},
      {"workout_session", "mood", %{}},
      {"workout_session", "tags", ["great_energy"]},
      {"workout_session", "tags", "unknown"},
      {"workout_session", "context_low_energy", %{}},
      {"workout_session", "primary_limiter", "unknown"},
      {"workout_session", "preference_feedback", true},
      {"workout_session", "burpee_type", "unknown"},
      {"workout_session", "client_session_id", %{}},
      {"tracking", "enabled", "true"},
      {"tracking", "trust", %{}},
      {"tracking", "trust", "unknown"},
      {"tracking", "reason", []},
      {"tracking", "detected_reps", true},
      {"tracking", "detected_duration_sec", %{}},
      {"tracking", "cadence_ms", %{}},
      {"tracking", "cadence_ms", [5_000, %{}]}
    ]

    for {section, field, forged} <- forged_payloads do
      plan = plan_fixture(user)
      assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
      assert {:ok, view, _html} = live(conn, ~p"/session/#{started.id}")
      attrs = Map.put(valid_attrs, "client_session_id", started.client_session_id)
      payload = %{"workout_session" => attrs, "tracking" => valid_tracking}
      payload = put_in(payload, [section, field], forged)

      render_hook(view, "save_session", payload)

      assert has_element?(view, "#burpee-session")
      assert Repo.get!(WorkoutSession, started.id).state == :started
    end
  end

  test "valid HTML string completion values remain accepted", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
    assert {:ok, view, _html} = live(conn, ~p"/session/#{started.id}")

    render_hook(view, "save_session", %{
      "workout_session" => %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => "4",
        "burpee_count_planned" => "5",
        "duration_sec_actual" => "20",
        "duration_sec_planned" => "25",
        "client_session_id" => started.client_session_id,
        "mood" => "1",
        "tags" => "great_energy",
        "context_low_energy" => "false",
        "context_high_energy" => "false",
        "context_heat_affected" => "false",
        "primary_limiter" => "legs",
        "preference_feedback" => "avoid",
        "note_post" => "HTML values"
      },
      "tracking" => %{
        "enabled" => true,
        "trust" => "finished",
        "reason" => nil,
        "detected_reps" => "4",
        "detected_duration_sec" => "20",
        "cadence_ms" => [5_000, 10_000, 15_000, 20_000]
      }
    })

    assert Repo.get!(WorkoutSession, started.id).state == :completed
  end

  test "foreign, completed, and missing session IDs do not mount", %{conn: conn, user: user} do
    other_user = user_fixture()
    other_plan = plan_fixture(other_user)
    assert {:ok, foreign} = Workouts.start_plan(other_user, other_plan.id, Ecto.UUID.generate())

    own_plan = plan_fixture(user)
    assert {:ok, completed} = Workouts.start_plan(user, own_plan.id, Ecto.UUID.generate())

    assert {:ok, completed} =
             Workouts.complete_session(
               user,
               completed.id,
               %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
               :timed
             )

    for session_id <- [foreign.id, completed.id, 2_147_483_647] do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/session/#{session_id}")
    end
  end

  test "renders the client-owned surface and leave/resume action", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    assert {:ok, session} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
    assert {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

    for id <- ~w[
          burpee-session
          session-capture-choice
          session-camera-status
          session-camera-setup
          session-warmup-choice
          session-workout-ready
          session-runner-client
          session-completion-review
          session-completion-form
          session-save-btn
          session-leave-btn
          session-live-status
        ] do
      assert has_element?(view, "##{id}")
    end

    assert has_element?(view, "#session-leave-btn", "Leave and resume later")
    refute has_element?(view, "#session-report-pending-status")
    refute has_element?(view, "#session-report-pending-retry")
    refute has_element?(view, "#session-abort-btn")
  end

  defp runner_events(program_json) do
    program_json
    |> Map.get("events", [])
    |> Enum.map(fn event ->
      case event["kind"] do
        "work" ->
          %{
            "kind" => "work",
            "reps" => event["reps"],
            "sec_per_rep" => event["sec_per_rep_us"] / 1_000_000,
            "sec_per_burpee" =>
              Map.get(event, "sec_per_burpee_us", event["sec_per_rep_us"]) / 1_000_000,
            "duration_sec" => event["duration_sec"]
          }

        "rest" ->
          %{"kind" => "rest", "duration_sec" => event["duration_ms"] / 1000}
      end
    end)
  end
end
