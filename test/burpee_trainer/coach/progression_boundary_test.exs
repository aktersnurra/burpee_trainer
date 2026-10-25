defmodule BurpeeTrainer.Coach.ProgressionBoundaryTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Coach, LayoutFixtures, Workouts}
  alias Coach.{AgentPrompt, Policy}
  alias Coach.Tools.{ProposeWorkout, SelectWorkout}

  setup do
    scope = scope_fixture()

    session =
      free_form_session_fixture(scope.user, %{
        burpee_count_actual: 100,
        duration_sec_actual: 1200,
        completed_at: DateTime.add(DateTime.utc_now(:second), -7, :day)
      })

    free_form_session_fixture(user_fixture(), %{
      burpee_count_actual: 300,
      duration_sec_actual: 1200
    })

    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    slot = %{slot | burpee_type: :six_count, duration_sec: 1200}
    {:ok, selected} = Workouts.ensure_home_selection(scope, slot)

    %{
      scope: scope,
      slot: slot,
      session: session,
      run: %{
        slot: slot,
        expected_selection: selected,
        run_id: Ecto.UUID.generate(),
        call_index: 1
      }
    }
  end

  test "the model receives the owned evidence and repeat constraints", ctx do
    context = AgentPrompt.context(ctx.scope, ctx.slot)
    assert context.progression.action == :repeat
    assert context.progression.evidence_ids == [ctx.session.id]
    assert context.progression.max_reps_per_20 == 100
  end

  test "automatic saved selection cannot exceed a repeat decision but manual selection can",
       ctx do
    plan = plan_fixture(ctx.scope.user, %{target_reps: 110, target_duration_sec: 1200})

    assert {:error, _} =
             SelectWorkout.call(
               ctx.scope,
               %{"plan_id" => plan.id, "rationale" => "Repeat."},
               ctx.run
             )

    assert {:ok, selected} =
             Workouts.select_home_workout(ctx.scope, ctx.run.expected_selection, plan.id)

    assert selected.plan.id == plan.id
  end

  test "automatic generation cannot bypass repeat constraints", ctx do
    args = %{
      "reps" => 110,
      "pacing_style" => "even",
      "recovery" => "required",
      "timed_rests" => [],
      "requested_pace_sec" => 5.0,
      "layout" => LayoutFixtures.layout([List.duplicate({10, 5.0, 5.0}, 11)])
    }

    assert {:error, _} = ProposeWorkout.call(ctx.scope, args, ctx.run)
  end
end
