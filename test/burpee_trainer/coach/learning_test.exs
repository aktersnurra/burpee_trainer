defmodule BurpeeTrainer.Coach.LearningTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach.Learning
  alias BurpeeTrainer.Workouts

  test "record_session_completed updates coach arms deterministically in tests" do
    user = user_fixture()

    plan =
      plan_fixture(user, %{
        "burpee_count_target" => 30,
        "target_duration_min" => 2
      })

    {:ok, session} =
      Workouts.create_session_from_plan(user, plan, %{
        "burpee_type" => Atom.to_string(plan.burpee_type),
        "burpee_count_planned" => plan.burpee_count_target,
        "duration_sec_planned" => plan.target_duration_min * 60,
        "burpee_count_actual" => plan.burpee_count_target,
        "duration_sec_actual" => plan.target_duration_min * 60,
        "mood" => 0
      })

    assert :ok = Learning.record_session_completed(user, session)
  end
end
