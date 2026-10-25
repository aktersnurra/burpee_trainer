defmodule BurpeeTrainer.Coach.ApproveAndSelectTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Coach, Repo, Workouts}
  alias BurpeeTrainer.Coach.{Policy, WorkoutRequest}
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  setup do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, selected} = Workouts.ensure_home_selection(scope, slot)
    plan = plan_fixture(scope.user, %{target_reps: 40, target_duration_sec: 1200})

    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 40,
        "target_duration_sec" => 1200,
        "pacing_style" => "even",
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => nil
      })

    prepared = %{
      user_id: scope.user.id,
      approval_key: Ecto.UUID.generate(),
      definition: plan.definition_json,
      request: request,
      original_request: request,
      text: "Reviewed workout"
    }

    %{scope: scope, slot: slot, selected: selected, prepared: prepared}
  end

  test "Use publishes and selects atomically without creating a session", ctx do
    assert {:ok, selection} = Coach.approve_and_select_plan(ctx.scope, ctx.prepared, ctx.selected)
    assert selection.plan.approval_key == ctx.prepared.approval_key
    assert selection.plan.state == :published
    assert {:ok, ^selection} = Workouts.ensure_home_selection(ctx.scope, ctx.slot)
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "stale review cannot publish an orphan or overwrite a newer choice", ctx do
    other = plan_fixture(ctx.scope.user)
    {:ok, newer} = Workouts.select_home_workout(ctx.scope, ctx.selected, other.id)
    count = Repo.aggregate(WorkoutPlan, :count)
    assert {:error, _} = Coach.approve_and_select_plan(ctx.scope, ctx.prepared, ctx.selected)
    assert Repo.aggregate(WorkoutPlan, :count) == count
    assert {:ok, ^newer} = Workouts.ensure_home_selection(ctx.scope, ctx.slot)
  end
end
