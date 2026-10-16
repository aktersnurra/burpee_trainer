defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
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

    assert {:ok, session} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

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

  test "idle pre-workout panels show the selected workout and an icon-only way home", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{name: "Three steady sets"})

    assert {:ok, session} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    assert {:ok, view, _} = live(conn, ~p"/session/#{session.id}")

    for panel <- ~w[session-camera-setup] do
      assert has_element?(view, "##{panel} .session-preflight-workout-name", plan.name)

      assert has_element?(
               view,
               "##{panel} .session-preflight-back[aria-label='Back to Home'][href='/'] .hero-arrow-left"
             )
    end

    refute has_element?(view, "#session-runner-client .session-preflight-chrome")
    refute has_element?(view, "#session-completion-review .session-preflight-chrome")
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "back to Home preserves the started session for resume", %{conn: conn, user: user} do
    plan = plan_fixture(user)

    assert {:ok, session} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    assert {:ok, view, _} = live(conn, ~p"/session/#{session.id}")

    view |> element("#session-camera-setup-back") |> render_click()
    assert_redirect(view, ~p"/")
    assert Repo.get!(WorkoutSession, session.id).state == :started
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "discarding a started session deletes it and nothing else", %{conn: conn, user: user} do
    scope = Scope.for_user(user)
    plan = plan_fixture(user)
    {:ok, kept} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())

    {:ok, kept} =
      Workouts.complete_session(
        scope,
        kept.id,
        %{burpee_count_actual: 9, duration_sec_actual: 60},
        :timed
      )

    {:ok, session} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())

    {:ok, view, _} = live(conn, ~p"/session/#{session.id}")
    assert has_element?(view, "#session-discard-btn[type=button][aria-label='Discard session']")
    assert has_element?(view, "#session-discard-confirm[hidden]", "Nothing will be saved")

    render_hook(view, "discard_session", %{})
    assert_reply(view, %{status: "discarded"})

    refute Repo.get(WorkoutSession, session.id)
    assert Repo.get!(WorkoutSession, kept.id).state == :completed
  end

  test "a completed session cannot be discarded from the finish screen", %{
    conn: conn,
    user: user
  } do
    scope = Scope.for_user(user)
    plan = plan_fixture(user)
    {:ok, session} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())
    {:ok, view, _} = live(conn, ~p"/session/#{session.id}")

    {:ok, _} =
      Workouts.complete_session(
        scope,
        session.id,
        %{burpee_count_actual: 9, duration_sec_actual: 60},
        :timed
      )

    render_hook(view, "discard_session", %{})
    assert_reply(view, %{status: "error"})
    assert Repo.get!(WorkoutSession, session.id).state == :completed
  end

  test "the paused workout can go back to Home and keep the session", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    {:ok, session} = Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())
    {:ok, view, _} = live(conn, ~p"/session/#{session.id}")

    assert has_element?(
             view,
             "#session-pause-actions #session-pause-leave[aria-label='Back to Home'][href='/'] .hero-arrow-left"
           )

    view |> element("#session-pause-leave") |> render_click()
    assert_redirect(view, ~p"/")
    assert Repo.get!(WorkoutSession, session.id).state == :started
  end

  test "a started snapshot remains executable after its plan is archived", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)

    assert {:ok, session} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    snapshot = session.program_snapshot
    assert {:ok, _archived} = Workouts.archive_plan(Scope.for_user(user), plan.id)

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

    assert {:ok, started} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

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
    # No mood was chosen, so none is stored.
    assert completed.mood == nil

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

      assert {:ok, started} =
               Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

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

    assert {:ok, started} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

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

  test "renders the client-owned surface and minimal completion review", %{conn: conn, user: user} do
    plan = plan_fixture(user)

    assert {:ok, session} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    assert {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

    for id <- ~w[
          burpee-session
          session-camera-setup
          session-runner-client
          session-completion-review
          session-completion-form
          session-save-btn
          session-discard-btn
          session-live-status
        ] do
      assert has_element?(view, "##{id}")
    end

    # Nothing asks before the workout: the client opens the camera or the countdown.
    assert has_element?(view, "#session-camera-setup[hidden][inert]")
    assert has_element?(view, "#session-runner-client[hidden][inert]")
    assert has_element?(view, "#camera-setup-heading", "Starting camera")
    assert has_element?(view, "#camera-setup-retry[hidden] .hero-arrow-path")
    assert has_element?(view, "#camera-setup-continue", "Continue without camera")

    for removed <- ~w[session-capture-choice session-camera-status session-warmup-choice
                      session-workout-ready] do
      refute has_element?(view, "##{removed}")
    end

    assert has_element?(view, "#session-completion-heading", "Workout complete")
    assert has_element?(view, "#session-completion-form > .grid + #session-completion-mood")
    assert has_element?(view, "#session-completion-mood [data-mood='-1']", "Rough")
    assert has_element?(view, "#session-completion-mood [data-mood='0']", "OK")
    assert has_element?(view, "#session-completion-mood [data-mood='1']", "Good")
    # The counted result is the answer; each field opens only when asked for, but stays in
    # the form.
    for name <- ~w[reps duration] do
      assert has_element?(view, "#session-completion-form #completion-#{name}-field[hidden]")
      assert has_element?(view, "#completion-#{name}-field #completion-#{name}-input")
    end

    assert has_element?(
             view,
             "#completion-reps-edit[type=button][aria-label='Correct reps'] #session-actual-reps"
           )

    assert has_element?(
             view,
             "#completion-duration-edit[type=button][aria-label='Correct time'] #session-actual-duration"
           )

    # Save or discard: no leaving to come back later, and nothing behind a button.
    for removed <- ~w[completion-note-toggle completion-note-field session-leave-btn] do
      refute has_element?(view, "##{removed}")
    end

    # Tags and a note sit under mood, optional, in Home's pill and field styles.
    for {tag, label} <- [
          {"tired", "Tired"},
          {"great_energy", "Great energy"},
          {"bad_sleep", "Bad sleep"},
          {"sick", "Sick"},
          {"travel", "Travel"},
          {"hot", "Hot"}
        ] do
      assert has_element?(
               view,
               "#session-completion-mood + #session-completion-tags[role=group][aria-label=Tags] " <>
                 "button.session-tag-pill[type=button][data-tag=#{tag}][aria-pressed=false]",
               label
             )
    end

    assert has_element?(
             view,
             "#session-completion-tags + .session-note-field " <>
               "textarea#completion-note-input.session-note-input[rows='1'][placeholder='How did it go?']"
           )

    assert has_element?(view, "label.sr-only[for=completion-note-input]", "Note")

    refute has_element?(view, "#session-more-feedback")
    refute has_element?(view, "#session-typed-feedback")

    assert has_element?(
             view,
             "#session-save-btn[aria-label='Save session'] #session-save-icon-ready .hero-check"
           )

    assert has_element?(view, "#session-save-icon-pending[hidden] .hero-arrow-path")

    assert has_element?(view, "#session-discard-btn[aria-label='Discard session'] .hero-trash")
    refute has_element?(view, "#session-save-btn", "Save session")
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
