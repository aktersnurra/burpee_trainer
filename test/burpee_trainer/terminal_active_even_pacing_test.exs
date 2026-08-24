defmodule BurpeeTrainer.TerminalActiveEvenPacingTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.{PlanCompiler, Planner}

  alias BurpeeTrainer.PlanCompiler.{
    CompileError,
    Program,
    ProgramEvent,
    ProgramHash,
    ProgramValidator
  }

  alias BurpeeTrainer.PlanSolver.{Execution, ExplicitRest, Input}

  test "two-rep even program uses full cadence before the terminal active interval" do
    assert {:ok, program} =
             compile_even(%{target_reps: 2, target_duration_sec: 20, block_pattern: [1]})

    [first, final] = program.events
    assert program.schema_version == 3
    assert_in_delta first.sec_per_rep, 20.0 - final.sec_per_burpee, 1.0e-6
    assert_in_delta first.duration_sec, first.sec_per_rep, 1.0e-6
    assert_in_delta final.duration_sec, final.sec_per_burpee, 1.0e-6
    assert_in_delta Program.duration_sec(program), 20.0, 1.0e-6
    assert match?(%ProgramEvent.Work{}, List.last(program.events))
  end

  test "split even program keeps a uniform cadence and preserves an explicit rest boundary" do
    assert {:ok, program} =
             compile_even(%{
               target_reps: 4,
               target_duration_sec: 40,
               block_pattern: [2],
               explicit_rests: [%{target_elapsed_sec: 16, duration_sec: 10, tolerance_sec: 1}]
             })

    [first, rest, final] = program.events
    cadence = (40 - 10 - final.sec_per_burpee) / 3

    assert_in_delta first.sec_per_rep, cadence, 1.0e-6
    assert_in_delta final.sec_per_rep, cadence, 1.0e-6
    assert_in_delta first.duration_sec, 2 * cadence, 1.0e-6
    assert_in_delta final.duration_sec, cadence + final.sec_per_burpee, 1.0e-6
    assert_in_delta first.duration_sec, 16.0, 1.0
    assert rest.duration_sec == 10
    assert_in_delta Program.duration_sec(program), 40.0, 1.0e-6
  end

  test "later explicit rests use elapsed boundaries including earlier explicit rests" do
    assert {:ok, program} =
             compile_even(%{
               target_reps: 6,
               target_duration_sec: 70,
               block_pattern: [2],
               explicit_rests: [
                 %{target_elapsed_sec: 22, duration_sec: 5, tolerance_sec: 1},
                 %{target_elapsed_sec: 49, duration_sec: 5, tolerance_sec: 1}
               ]
             })

    [first, first_rest, second, second_rest, final] = program.events
    cadence = (70 - 5 - 5 - final.sec_per_burpee) / 5
    first_boundary = 2 * cadence
    second_boundary = 4 * cadence + first_rest.duration_sec

    assert_in_delta first.duration_sec, first_boundary, 1.0e-6
    assert_in_delta second.duration_sec, 2 * cadence, 1.0e-6
    assert_in_delta first.duration_sec, 22.0, 1.0

    assert_in_delta first.duration_sec + first_rest.duration_sec + second.duration_sec,
                    second_boundary,
                    1.0e-6

    assert_in_delta second_boundary, 49.0, 1.0
    assert_in_delta second_rest.duration_sec, 5.0, 1.0e-6
  end

  test "one-rep even programs are active-only and reject incompatible durations and rests" do
    assert {:ok, program} =
             compile_even(%{target_reps: 1, target_duration_sec: 5, block_pattern: [1]})

    [work] = program.events
    assert_in_delta work.sec_per_burpee, 5.0, 1.0e-6
    assert_in_delta work.duration_sec, 5.0, 1.0e-6

    assert {:error, %CompileError{code: :solver_infeasible}} =
             compile_even(%{target_reps: 1, target_duration_sec: 2, block_pattern: [1]})

    assert {:error, %CompileError{code: :solver_infeasible}} =
             compile_even(%{
               target_reps: 1,
               target_duration_sec: 10,
               block_pattern: [1],
               explicit_rests: [%{target_elapsed_sec: 5, duration_sec: 5, tolerance_sec: 1}]
             })
  end

  test "schema-three work duration serializes, hashes, validates, and schema-two work remains legacy" do
    work =
      ProgramEvent.work!(%{reps: 2, sec_per_rep: 10.0, sec_per_burpee: 5.0, duration_sec: 15.0})

    assert {:ok, schema_three} =
             Program.new(%{
               schema_version: 3,
               solver_version: 5,
               burpee_type: :six_count,
               target_reps: 2,
               target_duration_sec: 15,
               events: [work],
               metadata: %{pacing_style: :even}
             })

    assert :ok = ProgramValidator.validate(schema_three)
    assert Program.duration_sec(schema_three) == 15.0

    assert ProgramHash.canonical_map(schema_three).events == [
             %{
               kind: "work",
               reps: 2,
               sec_per_rep_us: 10_000_000,
               sec_per_burpee_us: 5_000_000,
               duration_sec: 15.0
             }
           ]

    legacy_work = ProgramEvent.work!(%{reps: 2, sec_per_rep: 10.0, sec_per_burpee: 5.0})

    assert {:error, %CompileError{code: :invalid_work_duration}} =
             ProgramValidator.validate(%{
               schema_three
               | target_duration_sec: 20,
                 events: [legacy_work]
             })

    wrong_duration =
      ProgramEvent.work!(%{reps: 2, sec_per_rep: 10.0, sec_per_burpee: 5.0, duration_sec: 10.0})

    assert {:error, %CompileError{code: :invalid_work_duration}} =
             ProgramValidator.validate(%{
               schema_three
               | target_duration_sec: 10,
                 events: [wrong_duration]
             })

    assert {:ok, schema_two} =
             Program.new(%{
               schema_version: 2,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 2,
               target_duration_sec: 20,
               events: [legacy_work],
               metadata: %{pacing_style: :even}
             })

    assert :ok = ProgramValidator.validate(schema_two)
    assert Program.duration_sec(schema_two) == 20.0
    refute ProgramHash.hash(schema_three) == ProgramHash.hash(schema_two)
  end

  test "serialized schema-three work durations preserve the exact runner total" do
    assert {:ok, program} =
             compile_even(%{target_reps: 7, target_duration_sec: 100, block_pattern: [1]})

    events = ProgramHash.canonical_map(program).events

    assert Enum.all?(events, fn
             %{kind: "work", duration_sec: duration_sec} when is_float(duration_sec) -> true
             _event -> false
           end)

    assert Enum.reduce(events, 0.0, fn %{duration_sec: duration_sec}, total ->
             total + duration_sec
           end) == 100.0
  end

  test "generated plan and compiler program preserve the target duration and end in work" do
    input = %Input{
      name: "terminal active",
      burpee_type: :six_count,
      target_duration_sec: 40,
      burpee_count_target: 4,
      pacing_style: :even,
      block_pattern: [2],
      explicit_rests: [
        %ExplicitRest{target_elapsed_sec: 16, duration_sec: 10, tolerance_sec: 1}
      ]
    }

    assert {:ok, generated} = BurpeeTrainer.PlanSolver.generate_plan(input)
    assert_in_delta Planner.summary(generated.plan).duration_sec_total, 40.0, 1.0e-6
    assert_in_delta Execution.duration_sec(generated.execution), 40.0, 1.0e-6
    assert match?(%Execution.SetEvent{}, List.last(generated.execution))
  end

  defp compile_even(overrides) do
    PlanCompiler.compile(
      Map.merge(
        %{
          name: "terminal active",
          burpee_type: :six_count,
          target_reps: 2,
          target_duration_sec: 20,
          pacing_style: :even,
          block_pattern: [1],
          explicit_rests: []
        },
        overrides
      )
    )
  end
end
