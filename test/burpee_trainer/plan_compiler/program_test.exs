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
                 ProgramEvent.work!(%{
                   id: "work-001",
                   set_index: 1,
                   block_index: 1,
                   reps: 10,
                   duration_sec: 120.0,
                   sec_per_rep: 12.0,
                   label: "Set 1"
                 }),
                 ProgramEvent.rest!(%{id: "rest-001", duration_sec: 60, label: "Rest"}),
                 ProgramEvent.work!(%{
                   id: "work-002",
                   set_index: 2,
                   block_index: 1,
                   reps: 10,
                   duration_sec: 120.0,
                   sec_per_rep: 12.0,
                   label: "Set 2"
                 })
               ],
               metadata: %{pacing_style: :even}
             })

    assert length(Program.events(program)) == 3
    assert Program.total_reps(program) == 20
    assert_in_delta Program.duration_sec(program), 300.0, 1.0e-6
    assert :ok = ProgramValidator.validate(program)
  end

  test "validator rejects duplicate event ids" do
    event =
      ProgramEvent.work!(%{
        id: "work-001",
        set_index: 1,
        block_index: 1,
        reps: 10,
        duration_sec: 120.0,
        sec_per_rep: 12.0,
        label: "Set 1"
      })

    assert {:ok, program} =
             Program.new(%{
               schema_version: 1,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 20,
               target_duration_sec: 240,
               events: [event, %{event | set_index: 2}],
               metadata: %{pacing_style: :even}
             })

    assert {:error, %CompileError{code: :duplicate_event_id, context: %{id: "work-001"}}} =
             ProgramValidator.validate(program)
  end

  test "validator rejects target duration mismatch" do
    assert {:ok, program} =
             Program.new(%{
               schema_version: 1,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 10,
               target_duration_sec: 300,
               events: [
                 ProgramEvent.work!(%{
                   id: "work-001",
                   set_index: 1,
                   block_index: 1,
                   reps: 10,
                   duration_sec: 120.0,
                   sec_per_rep: 12.0,
                   label: "Set 1"
                 })
               ],
               metadata: %{pacing_style: :even}
             })

    assert {:error, %CompileError{code: :target_duration_mismatch}} =
             ProgramValidator.validate(program)
  end
end
