defmodule BurpeeTrainer.ExecutionProgramsTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.ExecutionPrograms
  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent}

  defp program do
    {:ok, program} =
      Program.new(%{
        schema_version: 1,
        solver_version: 4,
        burpee_type: :six_count,
        target_reps: 10,
        target_duration_sec: 120,
        events: [ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0})],
        metadata: %{pacing_style: :even, recovery_model: :saved_up_rest}
      })

    program
  end

  test "get_or_insert deduplicates identical programs by content hash" do
    assert {:ok, first} = ExecutionPrograms.get_or_insert(program())
    assert {:ok, second} = ExecutionPrograms.get_or_insert(program())

    assert first.id == second.id
    assert first.content_hash == second.content_hash
    assert first.target_reps == 10
    assert first.target_duration_sec == 120
    assert first.event_count == 1
  end
end
