defmodule BurpeeTrainer.Coach.DurationChoiceTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Coach, Repo, Workouts}
  alias BurpeeTrainer.Coach.{DurationChoice, Policy}
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  test "sixty remaining minutes permits either 20 or 40, never more than remains" do
    assert DurationChoice.options(%{home_state: :workout_needed, remaining_sec: 3600}) == [
             1200,
             2400
           ]

    assert DurationChoice.options(%{home_state: :workout_needed, remaining_sec: 1200}) == [1200]
    assert DurationChoice.options(%{home_state: :week_complete, remaining_sec: 0}) == []
  end

  test "duration review is local, exact and unselected until Use" do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, before} = Workouts.ensure_home_selection(scope, slot)
    original = plan_fixture(scope.user, %{target_reps: 60, target_duration_sec: 1200})
    {:ok, before} = Workouts.select_home_workout(scope, before, original.id)
    count = Repo.aggregate(WorkoutPlan, :count)
    assert {:ok, prepared} = DurationChoice.prepare(scope, before, 2400)
    assert prepared.definition["target_duration_sec"] == 2400
    assert prepared.definition["target_reps"] == 120
    assert Repo.aggregate(WorkoutPlan, :count) == count
    assert llm_call_count(scope) == 0
    assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
    assert {:ok, used} = Coach.approve_and_select_plan(scope, prepared, before)
    assert used.plan.target_duration_sec == 2400
    assert Workouts.verify_plan_content(used.plan) == :ok
    assert Repo.aggregate(WorkoutSession, :count) == 0
    assert Repo.get!(WorkoutPlan, original.id).content_hash == original.content_hash
  end

  test "a forty-minute selection can return to twenty minutes at the same rate" do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, selected} = Workouts.ensure_home_selection(scope, slot)
    plan = plan_fixture(scope.user, %{target_reps: 120, target_duration_sec: 2400})
    {:ok, selected} = Workouts.select_home_workout(scope, selected, plan.id)
    assert {:ok, prepared} = DurationChoice.prepare(scope, selected, 1200)
    assert prepared.definition["target_reps"] == 60
    assert prepared.definition["target_duration_sec"] == 1200
    assert {:error, _} = DurationChoice.prepare(scope_fixture(), selected, 1200)
    assert {:ok, ^selected} = Workouts.ensure_home_selection(scope, slot)
  end

  test "invalid and over-budget choices leave the selection untouched" do
    scope = scope_fixture()
    free_form_session_fixture(scope.user, %{duration_sec_actual: 3600})
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, before} = Workouts.ensure_home_selection(scope, slot)

    for duration <- [0, "2400", 2400, 4800] do
      assert {:error, _} = DurationChoice.prepare(scope, before, duration)
    end

    assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
  end
end
