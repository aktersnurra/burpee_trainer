defmodule BurpeeTrainer.PlanCompilerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.{CompileError, PlanSource, Program, ProgramEvent}

  test "compiles saved-up even rest source into canonical program events" do
    source = %{
      name: "100 in 20",
      burpee_type: :six_count,
      target_reps: 100,
      target_duration_sec: 1_200,
      pacing_style: :even,
      block_pattern: [10],
      explicit_rests: [%{target_elapsed_sec: 600, duration_sec: 60, tolerance_sec: 90}]
    }

    assert {:ok, %Program{} = program} = PlanCompiler.compile(source)
    assert Program.total_reps(program) == 100
    assert_in_delta Program.duration_sec(program), 1_200.0, 1.0e-6

    work_events = Enum.filter(program.events, &match?(%ProgramEvent.Work{}, &1))
    rest_events = Enum.filter(program.events, &match?(%ProgramEvent.Rest{}, &1))

    assert length(work_events) == 10
    assert length(rest_events) == 1
    assert Enum.map(work_events, & &1.reps) == List.duplicate(10, 10)
    assert Enum.map(Enum.take(work_events, 5), & &1.sec_per_rep) == List.duplicate(10.8, 5)
    assert Enum.map(Enum.drop(work_events, 5), & &1.sec_per_rep) == List.duplicate(12.0, 5)
  end

  test "compile errors are structured" do
    assert {:error, error} = PlanCompiler.compile(%{burpee_type: :six_count})
    assert error.code == :invalid_source
    assert is_binary(error.message)
    assert is_map(error.context)
  end

  test "malformed source numeric strings return structured errors" do
    assert {:error, %CompileError{code: :invalid_source, context: %{field: :target_reps}}} =
             PlanCompiler.compile(valid_source(%{target_reps: "not-a-number"}))

    assert {:error, %CompileError{code: :invalid_source, context: %{field: :target_duration_sec}}} =
             PlanSource.new(valid_source(%{target_duration_sec: "twenty-minutes"}))
  end

  test "malformed block pattern returns a structured error" do
    assert {:error, %CompileError{code: :invalid_source, context: %{field: :block_pattern}}} =
             PlanCompiler.compile(valid_source(%{block_pattern: [10, "bad"]}))

    assert {:error, %CompileError{code: :invalid_source, context: %{field: :block_pattern}}} =
             PlanCompiler.compile(valid_source(%{block_pattern: "10,10"}))
  end

  test "malformed explicit rests return structured errors" do
    assert {:error, %CompileError{code: :invalid_source, context: %{field: :explicit_rests}}} =
             PlanCompiler.compile(valid_source(%{explicit_rests: ["not-a-map"]}))

    assert {:error, %CompileError{code: :invalid_source, context: %{field: :explicit_rests}}} =
             PlanCompiler.compile(
               valid_source(%{
                 explicit_rests: [
                   %{target_elapsed_sec: 600, duration_sec: "bad", tolerance_sec: 90}
                 ]
               })
             )
  end

  defp valid_source(overrides) do
    Map.merge(
      %{
        name: "10 in 2",
        burpee_type: :six_count,
        target_reps: 10,
        target_duration_sec: 120,
        pacing_style: :even,
        block_pattern: [10],
        explicit_rests: []
      },
      overrides
    )
  end
end
