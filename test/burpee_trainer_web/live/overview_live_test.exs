defmodule BurpeeTrainerWeb.OverviewLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{WorkoutSession}

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
    assert has_element?(view, "#home-action")
    refute has_element?(view, "#resume-recommended-workout")
    refute has_element?(view, "#tell-coach-button")
    refute has_element?(view, "#manual-workout-form")
    assert recommendation.selected_workout_plan_id
  end

  test "Home replaces malformed pinned events before rendering inspection", %{
    conn: conn,
    user: user
  } do
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    {:ok, shown} = Workouts.ensure_home_selection(user, slot)
    plan = workout_plan_draft_fixture(user)

    Repo.get!(BurpeeTrainer.Workouts.CoachRecommendation, shown.recommendation_id)
    |> Ecto.Changeset.change(pending_draft_id: plan.id)
    |> Repo.update!()

    {:ok, pinned} = Workouts.select_home_workout(user, shown, plan.id)

    corrupt =
      plan
      |> Ecto.Changeset.change(
        definition_json: Map.put(plan.definition_json, "events", ["malformed"])
      )
      |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-ready-recommendation")
    assert has_element?(view, "#home-action")
    assert {:ok, fallback} = Workouts.ensure_home_selection(user, slot)
    assert fallback.plan.origin == :built_in
    assert fallback.home_revision == pinned.home_revision + 1
    assert Repo.reload!(corrupt) == corrupt
  end

  test "Home filters survive the browser button's empty value metadata", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-filter-toggle") |> render_click()

    # LiveView's browser client adds button.value after phx-value-* metadata.
    view |> element("#home-type-six_count") |> render_click(%{"value" => ""})
    assert has_element?(view, "#home-type-six_count[aria-pressed=false]")
    assert has_element?(view, "#home-type-navy_seal[aria-pressed=true]")

    view |> element("#home-level-level_1a") |> render_click(%{"value" => ""})
    assert has_element?(view, "#home-level-level_1a[aria-pressed=false]")
    assert has_element?(view, "#home-level-level_1b[aria-pressed=true]")
    view |> element("#home-filter-reset") |> render_click()
    assert has_element?(view, "#home-type-six_count[aria-pressed=true]")
    assert has_element?(view, "#home-level-level_1a[aria-pressed=true]")
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "Start creates the immutable server session before navigating by session id", %{
    conn: conn,
    user: user
  } do
    _recommendation = recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#home-adjustment-form", home_adjustment: %{instruction: ""}) |> render_submit()

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
      |> LazyHTML.query("input[name=client_session_id]")
      |> LazyHTML.attribute("value")

    params = %{
      "home_adjustment" => %{"instruction" => ""},
      "client_session_id" => client_session_id
    }

    render_click(
      view,
      "submit_home_action",
      Map.put(params, "client_session_id", Ecto.UUID.generate())
    )

    assert Repo.aggregate(WorkoutSession, :count) == 0

    render_click(view, "submit_home_action", params)

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

  test "failed Resume restores a usable workspace when the rendered session disappears", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)

    {:ok, started} =
      Workouts.start_plan(user, recommendation.selected_workout_plan_id, Ecto.UUID.generate())

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#resume-recommended-workout")
    refute has_element?(view, "#home-summary")

    Repo.delete!(started)
    view |> element("#resume-recommended-workout") |> render_click()

    refute has_element?(view, "#resume-recommended-workout")
    assert has_element?(view, "#home-summary")
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-expansion[data-open='true']")
    assert has_element?(view, "#home-adjustment-form")
    assert has_element?(view, "#home-action", "Start")
    assert Workouts.current_started_session(user) == nil
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "mount ensures a stable current-slot selection", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-summary")
    {:ok, selected} = Workouts.ensure_home_selection(user, slot!(user))
    {:ok, reloaded, _} = live(conn, ~p"/")
    assert has_element?(reloaded, "#home-workout-area")
    {:ok, same} = Workouts.ensure_home_selection(user, slot!(user))
    assert selected == same
  end

  test "expansion preserves DOM for both transition directions", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-expansion[data-open='false']")
    assert has_element?(view, "#home-expansion-content[inert][aria-hidden='true']")
    refute has_element?(view, "#desktop-home-nav")
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-expansion[data-open='true']")
    refute has_element?(view, "#home-expansion-content[inert]")
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-expansion-content[inert]")
    assert has_element?(view, "#home-adjustment-form")
  end

  test "submit does not trust the previous Start label", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()

    view
    |> form("#home-adjustment-form", home_adjustment: %{instruction: "Less rest"})
    |> render_submit()

    render_async(view)
    assert Workouts.current_started_session(user) == nil
    assert has_element?(view, "#home-action", "Update")
    assert has_element?(view, "#home-adjustment-error")
  end

  test "blank submit starts despite prior Update label and old events cannot mutate", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")

    for event <- ["start_recommendation", "use_candidate", "keep_current"] do
      render_click(view, event, %{})
    end

    assert Workouts.current_started_session(user) == nil

    view
    |> form("#home-adjustment-form", home_adjustment: %{instruction: "Less rest"})
    |> render_change()

    assert has_element?(view, "#home-action", "Update")

    view
    |> form("#home-adjustment-form", home_adjustment: %{instruction: "  "})
    |> render_submit()

    session = Workouts.current_started_session(user)
    assert_redirect(view, ~p"/session/#{session.id}")
  end

  test "malformed adjustment change is ignored", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "change_adjustment", %{"home_adjustment" => %{"instruction" => %{}}})
    assert has_element?(view, "#home-action", "Start")
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
