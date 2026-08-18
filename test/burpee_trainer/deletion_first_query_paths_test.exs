defmodule BurpeeTrainer.DeletionFirstQueryPathsTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan}

  test "owned supported catalog reads canonical published snapshots only" do
    user = user_fixture()
    other = user_fixture()
    published = plan_fixture(user, %{name: "Owned final plan"})
    _other_plan = plan_fixture(other, %{name: "Other plan"})
    _draft = workout_plan_draft_fixture(user, %{name: "Draft plan"})

    assert [%WorkoutPlan{} = catalog_plan] = Workouts.list_owned_supported_plans(user)
    assert catalog_plan.id == published.id
    assert catalog_plan.definition_json == published.definition_json
    assert catalog_plan.program_json == published.program_json
    assert catalog_plan.content_hash == published.content_hash
  end

  test "current recommendation preloads only canonical selection and candidate pointers" do
    user = user_fixture()

    assert {:ok, recommendation} =
             Workouts.ensure_recommendation(user, %{
               slot_key: "2026-08-27:standard",
               slot_date: ~D[2026-08-27],
               rationale: "Fallback selection"
             })

    assert %CoachRecommendation{} = current = Workouts.current_coach_recommendation(user)
    assert current.id == recommendation.id
    assert %WorkoutPlan{state: :published} = current.selected_workout_plan
    assert current.selected_workout_video == nil
    assert current.pending_draft == nil
    assert Workouts.pending_coach_clarification(current) == nil
  end

  test "recent coach history is bounded to sixteen completed non-warmup snapshots" do
    user = user_fixture()

    for offset <- 1..17 do
      completed_at = DateTime.add(DateTime.utc_now(:second), -offset * 60, :second)

      free_form_session_fixture(user, %{
        "burpee_count_actual" => offset,
        "duration_sec_actual" => 60,
        "completed_at" => completed_at
      })
    end

    _warmup =
      free_form_session_fixture(user, %{
        "tags" => "warmup",
        "completed_at" => DateTime.add(DateTime.utc_now(:second), -30, :second)
      })

    sessions = Workouts.list_recent_training_sessions(user)
    assert length(sessions) == 16
    assert Enum.all?(sessions, &(&1.state == :completed and &1.tags != "warmup"))
  end
end
