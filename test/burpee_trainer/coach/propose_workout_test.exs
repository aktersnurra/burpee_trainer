defmodule BurpeeTrainer.Coach.ProposeWorkoutTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{Policy, Tools.ProposeWorkout, Tools.SelectWorkout}
  alias BurpeeTrainer.{Workouts, LayoutFixtures}
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  defp run(scope, slot) do
    {:ok, expected} = Workouts.ensure_home_selection(scope, slot)
    %{slot: slot, run_id: Ecto.UUID.generate(), call_index: 1, expected_selection: expected}
  end

  defp args(reps, sets) do
    %{
      "reps" => reps,
      "pacing_style" => "even",
      "recovery" => "required",
      "timed_rests" => [],
      "requested_pace_sec" => 5.0,
      "layout" => LayoutFixtures.layout([sets])
    }
  end

  defp six_count_slot(scope, duration_sec) do
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    %{slot | burpee_type: :six_count, duration_sec: duration_sec}
  end

  defp completed!(scope, type, reps, completed_at) do
    Repo.insert!(%WorkoutSession{
      user_id: scope.user.id,
      state: :completed,
      source_kind: :manual,
      display_name_snapshot: "Logged",
      workout_type_snapshot: type,
      burpee_type: type,
      burpee_count_actual: reps,
      duration_sec_actual: 1200,
      completed_at: completed_at,
      capture_mode: :logged
    })
  end

  test "fits a slot-fixed canonical workout and stages it without persisting; invalid arguments have no effects" do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    run = run(scope, slot)

    assert {:ok, %{"duration_sec" => duration},
            %{
              pending_selection: %{
                definition: definition,
                approval_key: key,
                rationale: rationale
              }
            }} =
             ProposeWorkout.call(scope, args(20, [{10, 5.0, 5.0}, {10, 5.0, 5.0}]), run)

    assert duration == slot.duration_sec
    assert definition["target_duration_sec"] == slot.duration_sec
    assert definition["burpee_type"] == Atom.to_string(slot.burpee_type)
    assert key == run.run_id <> ":1"
    assert is_binary(rationale)
    refute Repo.get_by(WorkoutPlan, approval_key: key)
    assert {:ok, selection} = Workouts.ensure_home_selection(scope, slot)
    assert selection == run.expected_selection

    assert {:error, _} =
             ProposeWorkout.call(scope, args(300, [{150, 4.0, 4.0}, {150, 4.0, 4.0}]), run)

    assert {:error, _} = ProposeWorkout.call(scope, %{}, run)
  end

  test "both planner tools refuse a rationale that is not a short sentence for the athlete" do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    run = run(scope, slot)
    plan_id = run.expected_selection.plan.id

    for rationale <- [
          "   ",
          String.duplicate("Steady work today. ", 40),
          "You are at level_1a, so this stays easy."
        ] do
      proposal =
        put_in(args(20, [{10, 5.0, 5.0}, {10, 5.0, 5.0}]), ["layout", "rationale"], rationale)

      assert {:error, message} = ProposeWorkout.call(scope, proposal, run)
      assert message =~ "rationale"

      assert {:error, message} =
               SelectWorkout.call(scope, %{"plan_id" => plan_id, "rationale" => rationale}, run)

      assert message =~ "rationale"
    end

    named =
      put_in(args(20, [{10, 5.0, 5.0}, {10, 5.0, 5.0}]), ["layout", "name"], "level_1a steady")

    assert {:error, message} = ProposeWorkout.call(scope, named, run)
    assert message =~ "name"

    assert {:ok, _, %{pending_selection: %{rationale: "An easy twenty minutes."}}} =
             SelectWorkout.call(
               scope,
               %{"plan_id" => plan_id, "rationale" => "An easy twenty minutes."},
               run
             )
  end

  test "an easier workout below the current level is allowed" do
    scope = scope_fixture(%{"timezone" => "Etc/UTC"})
    two_days_ago = DateTime.add(DateTime.utc_now(:second), -2, :day)
    completed!(scope, :six_count, 100, two_days_ago)
    completed!(scope, :navy_seal, 40, two_days_ago)
    assert BurpeeTrainer.Levels.current_level(Workouts.list_sessions(scope)) == :level_1c

    slot = six_count_slot(scope, 1200)

    assert {:ok, _, _} =
             ProposeWorkout.call(
               scope,
               args(20, [{10, 5.0, 5.0}, {10, 5.0, 5.0}]),
               run(scope, slot)
             )
  end

  test "a long catch-up slot is held to the level band at a 20-minute-equivalent rate" do
    scope = scope_fixture()
    slot = six_count_slot(scope, 2400)
    run = run(scope, slot)

    # 120 reps in 40 minutes is 60 per 20 minutes: level_1b, the next level up from level_1a.
    assert {:ok, %{"duration_sec" => 2400}, _} =
             ProposeWorkout.call(scope, args(120, List.duplicate({10, 5.0, 5.0}, 12)), run)

    # 220 reps in 40 minutes is 110 per 20 minutes: level_1c, two levels up.
    assert {:error, "reps must not exceed the next level"} =
             ProposeWorkout.call(scope, args(220, List.duplicate({10, 5.0, 5.0}, 22)), run)
  end
end
