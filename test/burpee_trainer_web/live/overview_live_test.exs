defmodule BurpeeTrainerWeb.OverviewLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "Home renders one recommendation-first action without legacy authoring surfaces", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-ready-recommendation")
    assert has_element?(view, "#start-recommended-workout")
    refute has_element?(view, "#resume-recommended-workout")
    refute has_element?(view, "#tell-coach-button")
    refute has_element?(view, "#manual-workout-form")
    assert recommendation.selected_workout_plan_id
  end

  test "Start creates the immutable server session before navigating by session id", %{
    conn: conn,
    user: user
  } do
    _recommendation = recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#start-recommended-workout") |> render_click()

    session = Workouts.current_started_session(user)
    assert session.source_kind == :plan
    assert_redirect(view, ~p"/session/#{session.id}")
  end

  test "Start reuses the rendered token for duplicate delivery and rejects a forged token", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")

    [client_session_id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#start-recommended-workout")
      |> LazyHTML.attribute("phx-value-client-session-id")

    params = %{
      "plan-id" => Integer.to_string(recommendation.selected_workout_plan_id),
      "client-session-id" => client_session_id
    }

    render_click(
      view,
      "start_recommendation",
      Map.put(params, "client-session-id", Ecto.UUID.generate())
    )

    assert Repo.aggregate(WorkoutSession, :count) == 0

    render_click(view, "start_recommendation", params)

    [session] = Repo.all(WorkoutSession)

    assert {:ok, replayed} =
             Workouts.start_plan(
               user,
               recommendation.selected_workout_plan_id,
               client_session_id
             )

    assert replayed.id == session.id
    assert Repo.aggregate(WorkoutSession, :count) == 1
    assert session.client_session_id == client_session_id
    assert_redirect(view, ~p"/session/#{session.id}")
  end

  test "Home priority renders week complete before done today", %{conn: conn, user: user} do
    complete_history(user, DateTime.utc_now(:second), 4_800)
    _recommendation = recommendation_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-week-complete")
    refute has_element?(view, "#home-done-today")
    refute has_element?(view, "#home-ready-recommendation")
  end

  test "done today renders before the workout-needed recommendation", %{conn: conn, user: user} do
    complete_history(user, DateTime.utc_now(:second), 1_200)
    _recommendation = recommendation_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-done-today")
    refute has_element?(view, "#home-ready-recommendation")
  end

  test "week complete hides a persisted pending candidate and its actions", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)
    slot = slot!(user)

    assert {:ok, _recommendation} =
             Workouts.attach_candidate(user, recommendation.id, %{
               definition: definition_for(slot, "Hidden after completed week"),
               request_text: "Hidden after completed week",
               rationale: "A pending alternative."
             })

    complete_history(user, DateTime.utc_now(:second), 4_800)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-week-complete")
    refute has_element?(view, "#home-pending-candidate")
    refute has_element?(view, "#use-candidate-button")
    refute has_element?(view, "#keep-current-workout-button")
  end

  test "done today hides a persisted pending candidate and its actions", %{conn: conn, user: user} do
    recommendation = recommendation_fixture(user)
    slot = slot!(user)

    assert {:ok, _recommendation} =
             Workouts.attach_candidate(user, recommendation.id, %{
               definition: definition_for(slot, "Hidden after today's workout"),
               request_text: "Hidden after today's workout",
               rationale: "A pending alternative."
             })

    complete_history(user, DateTime.utc_now(:second), 1_200)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-done-today")
    refute has_element?(view, "#home-pending-candidate")
    refute has_element?(view, "#use-candidate-button")
    refute has_element?(view, "#keep-current-workout-button")
  end

  test "Resume uses the exact started session without creating another", %{conn: conn, user: user} do
    recommendation = recommendation_fixture(user)

    assert {:ok, started} =
             Workouts.start_plan(
               user,
               recommendation.selected_workout_plan_id,
               Ecto.UUID.generate()
             )

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#resume-recommended-workout[phx-value-session-id='#{started.id}']")

    view |> element("#resume-recommended-workout") |> render_click()
    assert_redirect(view, ~p"/session/#{started.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "pending candidate actions carry exact draft and rendered selection and Use publishes it",
       %{
         conn: conn,
         user: user
       } do
    recommendation = recommendation_fixture(user)
    slot = slot!(user)

    assert {:ok, recommendation} =
             Workouts.attach_candidate(user, recommendation.id, %{
               definition: definition_for(slot, "Use this measured option"),
               request_text: "Use this measured option",
               rationale: "A measured alternative."
             })

    {:ok, view, _html} = live(conn, ~p"/")

    selector =
      "#use-candidate-button[phx-value-draft-id='#{recommendation.pending_draft_id}'][phx-value-plan-id='#{recommendation.selected_workout_plan_id}']"

    assert has_element?(view, selector)

    assert has_element?(
             view,
             "#keep-current-workout-button[phx-value-draft-id='#{recommendation.pending_draft_id}']"
           )

    view |> element("#use-candidate-button") |> render_click()

    persisted = Workouts.current_coach_recommendation(user)
    assert persisted.selected_workout_plan_id == recommendation.pending_draft_id
    assert is_nil(persisted.pending_draft_id)
    assert Repo.get!(WorkoutPlan, persisted.selected_workout_plan_id).state == :published
    refute has_element?(view, "#home-pending-candidate")
  end

  test "Retry remains available while no generated recommendation exists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#retry-recommendation-button")
    view |> element("#retry-recommendation-button") |> render_click()
    assert has_element?(view, "#retry-recommendation-button")
  end

  test "pending candidate survives reload and rejecting it deletes only the draft", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)
    slot = slot!(user)

    assert {:ok, recommendation} =
             Workouts.attach_candidate(user, recommendation.id, %{
               definition: definition_for(slot, "Another measured option"),
               request_text: "Another measured option",
               rationale: "A measured alternative."
             })

    draft_id = recommendation.pending_draft_id
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-pending-candidate")

    {:ok, reloaded, _html} = live(conn, ~p"/")
    assert has_element?(reloaded, "#home-pending-candidate")

    reloaded |> element("#keep-current-workout-button") |> render_click()

    refute has_element?(reloaded, "#home-pending-candidate")
    assert {:error, _reason} = Workouts.get_draft(user, draft_id)

    assert Workouts.current_coach_recommendation(user).selected_workout_plan_id ==
             recommendation.selected_workout_plan_id
  end

  defp complete_history(user, completed_at, duration_sec) do
    %WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      display_name_snapshot: "Historical workout",
      workout_type_snapshot: :six_count,
      burpee_type: :six_count,
      burpee_count_actual: 20,
      duration_sec_actual: duration_sec,
      completed_at: completed_at,
      capture_mode: :logged
    }
    |> Repo.insert!()
  end

  defp recommendation_fixture(user) do
    slot = slot!(user)

    {:ok, recommendation} =
      Workouts.ensure_recommendation(user, %{
        slot_key: slot.slot_key,
        slot_date: slot.slot_date,
        rationale: "A steady workout for today."
      })

    recommendation
  end

  defp slot!(user) do
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    slot
  end

  defp definition_for(slot, name) do
    reps = 10
    cadence = slot.duration_sec / reps

    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => Atom.to_string(slot.burpee_type),
      "target_duration_sec" => slot.duration_sec,
      "target_reps" => reps,
      "pacing_style" => "even",
      "rationale" => "A measured reusable workout.",
      "events" => [
        %{
          "kind" => "work",
          "reps" => reps,
          "sec_per_rep" => cadence,
          "sec_per_burpee" => cadence
        }
      ]
    }
  end
end
