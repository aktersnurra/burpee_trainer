defmodule BurpeeTrainer.PlanCompiler.ProgramValidatorTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler.{CompileError, Program, ProgramEvent, ProgramValidator}

  test "accepts an exact canonical schema-three program" do
    assert :ok = ProgramValidator.validate(valid_program())
  end

  test "rejects any target-duration mismatch without legacy tolerance" do
    program = %{valid_program() | target_duration_sec: 21}

    assert {:error,
            %CompileError{
              code: :target_duration_mismatch,
              context: %{target_duration_sec: 21, actual_duration_sec: 20.0}
            }} = ProgramValidator.validate(program)
  end

  test "requires canonical definition semantics" do
    program = %{valid_program() | metadata: %{}}

    assert {:error, %CompileError{code: :invalid_program}} = ProgramValidator.validate(program)
  end

  defp valid_program do
    work =
      ProgramEvent.work!(%{
        reps: 2,
        sec_per_rep: 15.0,
        sec_per_burpee: 5.0,
        duration_sec: 20.0
      })

    {:ok, program} =
      Program.new(%{
        schema_version: 3,
        solver_version: 1,
        burpee_type: :six_count,
        target_reps: 2,
        target_duration_sec: 20,
        events: [work],
        metadata: %{definition_hash: String.duplicate("a", 64), pacing_style: :even}
      })

    program
  end
end
