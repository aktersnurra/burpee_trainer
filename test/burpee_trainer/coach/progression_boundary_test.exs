defmodule BurpeeTrainer.Coach.ProgressionBoundaryTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{AgentPrompt, Policy}

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

    %{scope: scope, slot: slot, session: session}
  end

  test "the model receives the owned evidence and repeat constraints", ctx do
    context = AgentPrompt.context(ctx.scope, ctx.slot)
    assert context.progression.action == :repeat
    assert context.progression.evidence_ids == [ctx.session.id]
    assert context.progression.max_reps_per_20 == 100
  end
end
