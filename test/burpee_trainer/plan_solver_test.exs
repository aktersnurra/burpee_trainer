defmodule BurpeeTrainer.PlanSolverTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.{BlockSpec, Execution, Input, Solution, StructureSearch}

  defp input(overrides) do
    Map.merge(
      %{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 20,
        pacing_style: :even,
        level: :level_1c,
        additional_rests: []
      },
      overrides
    )
    |> then(fn attrs -> struct!(Input, attrs) end)
  end

  test "sustainable_ceiling/2 delegates to PaceModel" do
    for type <- [:six_count, :navy_seal], level <- [:level_1a, :level_1c, :level_4, :graduated] do
      assert PlanSolver.sustainable_ceiling(type, level) ==
               BurpeeTrainer.PaceModel.fastest_recommended_sec_per_rep(type, level)
    end
  end

  test "default_reps_per_set/1 returns compatibility defaults" do
    assert PlanSolver.default_reps_per_set(:six_count) == 10
    assert PlanSolver.default_reps_per_set(:navy_seal) == 5
  end

  test "rejects non-positive preferred block pattern entries at compatibility boundary" do
    assert {:error, [msg]} =
             PlanSolver.solve(
               input(%{pacing_style: :even, burpee_count_target: 70, block_pattern: [4, 0]})
             )

    assert msg =~ "block pattern"
  end

  test "even solve preserves even style and exact persisted totals" do
    assert {:ok, %Solution{} = sol} =
             PlanSolver.solve(
               input(%{
                 pacing_style: :even,
                 burpee_count_target: 140,
                 target_duration_min: 20,
                 level: :level_3
               })
             )

    assert sol.metadata.solver_version == 3
    assert sol.metadata.strategy == :even
    assert sol.pacing_style == :even
    assert sol.prescription.pacing_style == :even

    assert_solution_matches_execution(
      input(%{target_duration_min: 20, burpee_count_target: 140}),
      sol
    )
  end

  test "even pace override pins movement pace while preserving total duration" do
    assert {:ok, sol} =
             PlanSolver.solve(
               input(%{
                 pacing_style: :even,
                 burpee_count_target: 60,
                 target_duration_min: 10,
                 sec_per_burpee_override: 7.0
               })
             )

    assert_in_delta sol.sec_per_burpee, 7.0, 1.0e-6

    assert_solution_matches_execution(
      input(%{target_duration_min: 10, burpee_count_target: 60}),
      sol
    )
  end

  test "generated unbroken 140-rep plan satisfies invariants without forcing one structure" do
    inp =
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 8,
        burpee_count_target: 140,
        target_duration_min: 20,
        level: :level_3
      })

    assert {:ok, sol} = PlanSolver.solve(inp)

    assert sol.metadata.solver_version == 3
    assert sol.metadata.strategy in [:generated_grammar, :balanced_fallback]
    assert sol.pacing_style == :unbroken
    assert sol.burpee_count == 140
    assert Enum.sum(sol.set_pattern) == 140
    assert Enum.all?(sol.set_pattern, &(&1 <= 8))
    assert is_binary(sol.metadata.structure_key)
    assert_solution_matches_execution(inp, sol)
  end

  test "manual tapered structure is preserved exactly" do
    {:ok, block1} = BlockSpec.new(5, [8])
    {:ok, block2} = BlockSpec.new(5, [7])
    {:ok, block3} = BlockSpec.new(5, [7, 6])

    inp = %Input{
      name: "manual",
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      level: :level_3,
      max_unbroken_reps: 8,
      block_structure: [block1, block2, block3],
      explicit_rests: []
    }

    assert {:ok, sol} = PlanSolver.solve(inp)
    assert StructureSearch.encode(sol.prescription.blocks) == "5x[8]|5x[7]|5x[7,6]"
    assert sol.metadata.strategy == :manual_structure
    assert_solution_matches_execution(inp, sol)
  end

  test "hard pace bounds are not silently relaxed" do
    assert {:error, [msg]} =
             PlanSolver.solve(
               input(%{
                 pacing_style: :unbroken,
                 reps_per_set: 8,
                 burpee_count_target: 144,
                 target_duration_min: 20,
                 level: :level_1a,
                 sec_per_burpee_override: 3.6
               })
             )

    assert msg =~ "hard pace bounds"
  end

  test "solve/1 is deterministic" do
    inp =
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 7,
        burpee_count_target: 70,
        target_duration_min: 10
      })

    assert {:ok, first} = PlanSolver.solve(inp)
    assert {:ok, second} = PlanSolver.solve(inp)

    assert first.sec_per_burpee == second.sec_per_burpee
    assert first.set_pattern == second.set_pattern
    assert first.rest_pattern_sec == second.rest_pattern_sec
    assert first.metadata.structure_key == second.metadata.structure_key
  end

  test "no v3 solution has final automatic recovery" do
    inp =
      input(%{
        name: "140",
        pacing_style: :unbroken,
        reps_per_set: 8,
        burpee_count_target: 140,
        target_duration_min: 20,
        level: :level_3
      })

    assert {:ok, sol} = PlanSolver.solve(inp)
    assert match?(%Execution.SetEvent{}, List.last(sol.execution))
  end

  test "short unbroken workout under 12 minutes has no automatic reset" do
    inp =
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 7,
        burpee_count_target: 70,
        target_duration_min: 10
      })

    assert {:ok, sol} = PlanSolver.solve(inp)

    refute Enum.any?(sol.execution, fn
             %Execution.RestEvent{source: {:auto_reset, _kind}} -> true
             _event -> false
           end)

    assert_solution_matches_execution(inp, sol)
  end

  test "unbroken solution has no final trailing rest" do
    inp =
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 8,
        burpee_count_target: 120,
        target_duration_min: 20
      })

    assert {:ok, sol} = PlanSolver.solve(inp)
    assert match?(%Execution.SetEvent{}, List.last(sol.execution))
    assert length(sol.rest_pattern_sec) == max(length(sol.set_pattern) - 1, 0)
  end

  for {type, minutes, reps, max_set} <- [
        {:six_count, 20, 140, 8},
        {:six_count, 30, 210, 10},
        {:six_count, 14, 96, 8},
        {:navy_seal, 20, 80, 5},
        {:navy_seal, 30, 120, 6}
      ] do
    test "v3 invariants hold for #{type} #{minutes}m #{reps} reps max #{max_set}" do
      inp =
        input(%{
          burpee_type: unquote(type),
          target_duration_min: unquote(minutes),
          burpee_count_target: unquote(reps),
          pacing_style: :unbroken,
          level: :level_3,
          reps_per_set: unquote(max_set)
        })

      assert {:ok, sol} = PlanSolver.solve(inp)
      assert Enum.sum(sol.set_pattern) == unquote(reps)
      assert Enum.all?(sol.set_pattern, &(&1 <= unquote(max_set)))
      assert Execution.burpee_count(sol.execution) == unquote(reps)
      assert_in_delta Execution.duration_sec(sol.execution), unquote(minutes) * 60, 1.0
      assert match?(%Execution.SetEvent{}, List.last(sol.execution))
      assert_solution_matches_execution(inp, sol)
    end
  end

  test "unbroken additional rest is placed as a separate persisted step" do
    inp =
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 8,
        burpee_count_target: 120,
        target_duration_min: 20,
        additional_rests: [%{target_min: 10, rest_sec: 45}]
      })

    assert {:ok, sol} = PlanSolver.solve(inp)

    assert Enum.any?(sol.plan.steps, &(&1.kind == :rest and &1.rest_sec == 45))
    assert_solution_matches_execution(inp, sol)
  end

  defp assert_solution_matches_execution(%Input{} = input, %Solution{} = sol) do
    expected_sec = input.target_duration_sec || input.target_duration_min * 60
    summary = BurpeeTrainer.Planner.summary(sol.plan)

    assert Execution.burpee_count(sol.execution) == input.burpee_count_target
    assert_in_delta Execution.duration_sec(sol.execution), expected_sec, 1.0e-6
    assert summary.burpee_count_total == input.burpee_count_target
    assert_in_delta summary.duration_sec_total, expected_sec, 1.0
  end
end
