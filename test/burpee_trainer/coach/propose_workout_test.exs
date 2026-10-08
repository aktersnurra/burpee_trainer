defmodule BurpeeTrainer.Coach.ProposeWorkoutTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{Policy, Tools.ProposeWorkout}
  alias BurpeeTrainer.{Workouts, LayoutFixtures}

  test "fits slot-fixed canonical workout and selects it; invalid arguments have no effects" do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    run = %{slot: slot, run_id: Ecto.UUID.generate(), call_index: 1}

    args = %{
      "reps" => 20,
      "pacing_style" => "even",
      "recovery" => "required",
      "timed_rests" => [],
      "requested_pace_sec" => 5.0,
      "layout" => LayoutFixtures.layout([[{10, 5.0, 5.0}, {10, 5.0, 5.0}]])
    }

    assert {:ok, %{"plan_id" => id, "duration_sec" => duration}} =
             ProposeWorkout.call(scope, args, run)

    assert duration == slot.duration_sec
    assert {:ok, %{plan: %{id: ^id}}} = Workouts.ensure_home_selection(scope, slot)
    assert {:error, _} = ProposeWorkout.call(scope, Map.put(args, "reps", 300), run)
    assert {:error, _} = ProposeWorkout.call(scope, %{}, run)
  end
end
