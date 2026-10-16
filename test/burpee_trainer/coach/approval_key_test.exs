defmodule BurpeeTrainer.Coach.ApprovalKeyTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Coach, Workouts}
  alias BurpeeTrainer.Coach.WorkoutRequest

  test "key replay is owned and exact, and validates before insertion" do
    scope = scope_fixture()
    plan = plan_fixture(scope.user)

    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => plan.target_reps,
        "target_duration_sec" => plan.target_duration_sec,
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
      source: nil,
      text: "copy"
    }

    assert {:ok, saved} = Coach.approve_plan(scope, prepared)
    assert saved.approval_key == prepared.approval_key
    assert {:ok, replay} = Coach.approve_plan(scope, prepared)
    assert replay.id == saved.id
    assert {:error, _} = Coach.approve_plan(scope_fixture(), prepared)
    assert {:error, _} = Coach.approve_plan(scope, put_in(prepared.definition["name"], "changed"))

    assert {:error, _} =
             Workouts.commit_approved_workout(scope_fixture(), plan.definition_json, "copy",
               approval_key: saved.approval_key
             )
  end

  test "published approval keys cannot be rewritten outside the approval boundary" do
    scope = scope_fixture()
    plan = plan_fixture(scope.user)

    assert_raise Exqlite.Error, ~r/approval_key_immutable/, fn ->
      Repo.update_all(from(p in BurpeeTrainer.Workouts.WorkoutPlan, where: p.id == ^plan.id),
        set: [approval_key: Ecto.UUID.generate()]
      )
    end
  end
end
