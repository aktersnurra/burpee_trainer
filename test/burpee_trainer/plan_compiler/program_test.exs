defmodule BurpeeTrainer.PlanCompiler.ProgramTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler.{CompileError, Program, ProgramEvent, ProgramValidator}

  test "valid program computes reps and duration from ordered events" do
    assert {:ok, program} =
             Program.new(%{
               schema_version: 1,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 20,
               target_duration_sec: 300,
               events: [
                 ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0}),
                 ProgramEvent.rest!(%{duration_sec: 60}),
                 ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0})
               ],
               metadata: %{pacing_style: :even}
             })

    assert length(Program.events(program)) == 3
    assert Program.total_reps(program) == 20
    assert_in_delta Program.duration_sec(program), 300.0, 1.0e-6
    assert :ok = ProgramValidator.validate(program)

    [first_work | _] = Program.events(program)
    assert Map.from_struct(first_work) == %{kind: :work, reps: 10, sec_per_rep: 12.0}
  end

  test "validator rejects invalid work instructions" do
    assert {:ok, program} =
             Program.new(%{
               schema_version: 1,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 20,
               target_duration_sec: 240,
               events: [ProgramEvent.work!(%{reps: 10, sec_per_rep: 0.0})],
               metadata: %{pacing_style: :even}
             })

    assert {:error, %CompileError{code: :invalid_event}} = ProgramValidator.validate(program)
  end

  test "validator rejects target duration mismatch" do
    assert {:ok, program} =
             Program.new(%{
               schema_version: 1,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 10,
               target_duration_sec: 300,
               events: [ProgramEvent.work!(%{reps: 10, sec_per_rep: 12.0})],
               metadata: %{pacing_style: :even}
             })

    assert {:error, %CompileError{code: :target_duration_mismatch}} =
             ProgramValidator.validate(program)
  end
end
