defmodule BurpeeTrainer.Coach.ToolsTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach.Tools.{
    ProposeGoal,
    History,
    Goals,
    Library,
    SelectWorkout
  }

  test "select_workout asks for the reason, not a restatement of the workout" do
    assert SelectWorkout.schema()["properties"]["rationale"]["description"] =~ "why, not what"
  end

  test "goal proposal and confirmation are scoped" do
    scope = scope_fixture()

    args = %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 150,
      "date_target" => Date.to_iso8601(Date.add(Date.utc_today(), 42))
    }

    assert {:ok, %{"goal_id" => id, "status" => "proposed"}} = ProposeGoal.call(scope, args, %{})
    assert {:error, :not_found} = BurpeeTrainer.Goals.confirm(scope_fixture(), id)
    assert {:ok, %{status: :active}} = BurpeeTrainer.Goals.confirm(scope, id)
    assert {:ok, %{"goal_id" => proposed_id}} = ProposeGoal.call(scope, args, %{})
    assert {:error, :not_found} = BurpeeTrainer.Goals.dismiss(scope_fixture(), proposed_id)
    assert {:ok, %{status: :abandoned}} = BurpeeTrainer.Goals.dismiss(scope, proposed_id)
    assert BurpeeTrainer.Goals.get_active_goal(scope, :six_count).id == id
  end

  test "read tools never expose foreign rows and selection refuses foreign plans" do
    scope = scope_fixture()
    other = scope_fixture()
    foreign = plan_fixture(other.user)
    session_from_plan_fixture(other.user, foreign)
    assert {:ok, %{"sessions" => []}} = History.call(scope, %{"weeks" => 4}, %{})
    assert {:ok, %{"goals" => []}} = Goals.call(scope, %{}, %{})
    assert {:ok, %{"plans" => plans}} = Library.call(scope, %{}, %{})
    refute Enum.any?(plans, &(&1["id"] == foreign.id))
    owned = plan_fixture(scope.user)
    completed = session_from_plan_fixture(scope.user, owned)

    assert {:ok, %{"sessions" => [%{"reps" => reps, "duration_sec" => duration}]}} =
             History.call(scope, %{"weeks" => 4}, %{})

    assert reps == completed.burpee_count_actual
    assert duration == completed.duration_sec_actual
    assert {:ok, %{"plans" => own_library}} = Library.call(scope, %{}, %{})
    assert Enum.any?(own_library, &(&1["id"] == owned.id))

    assert {:error, "plan not found"} =
             SelectWorkout.call(scope, %{"plan_id" => foreign.id, "rationale" => "r"}, %{})
  end

  test "goal baseline covers all six weeks, and progress excludes foreign sessions" do
    scope = scope_fixture()
    other = scope_fixture()

    historical = fn owner, reps, at ->
      Repo.insert!(%BurpeeTrainer.Workouts.WorkoutSession{
        user_id: owner.user.id,
        state: :completed,
        source_kind: :manual,
        display_name_snapshot: "Logged",
        workout_type_snapshot: :six_count,
        burpee_type: :six_count,
        burpee_count_actual: reps,
        duration_sec_actual: 1200,
        completed_at: at,
        capture_mode: :logged
      })
    end

    historical.(scope, 75, DateTime.add(DateTime.utc_now(:second), -30, :day))
    historical.(other, 300, DateTime.utc_now(:second))
    for _ <- 1..17, do: historical.(scope, 10, DateTime.utc_now(:second))

    args = %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 150,
      "date_target" => Date.to_iso8601(Date.add(Date.utc_today(), 42))
    }

    assert {:ok, %{"goal_id" => id}} = ProposeGoal.call(scope, args, %{})
    assert Repo.get!(BurpeeTrainer.Goals.Goal, id).burpee_count_baseline == 75
    historical.(scope, 100, DateTime.utc_now(:second))

    assert {:ok,
            %{"goals" => [%{"progress" => %{"current_reps" => 100, "fraction" => fraction}}]}} =
             Goals.call(scope, %{}, %{})

    assert_in_delta fraction, 1 / 3, 0.0001
  end

  test "invalid goal targets return actionable validation fields without creating goals" do
    scope = scope_fixture()

    args = %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 400,
      "date_target" => Date.to_iso8601(Date.add(Date.utc_today(), 42))
    }

    assert {:error, detail} = ProposeGoal.call(scope, args, %{})
    assert detail =~ "burpee_count_target"
    assert detail =~ "cannot exceed 325"
    assert BurpeeTrainer.Goals.list(scope) == []
  end
end
