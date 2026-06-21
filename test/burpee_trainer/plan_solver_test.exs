defmodule BurpeeTrainer.PlanSolverTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.{Input, Solution}

  defp input(overrides \\ %{}) do
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
    |> then(fn m -> struct!(Input, m) end)
  end

  test "sustainable_ceiling/2 delegates to PaceModel for six_count levels" do
    for level <- [:level_1a, :level_1c, :level_4, :graduated] do
      assert PlanSolver.sustainable_ceiling(:six_count, level) ==
               BurpeeTrainer.PaceModel.fastest_recommended_sec_per_rep(:six_count, level)
    end
  end

  test "sustainable_ceiling/2 delegates to PaceModel for navy_seal levels" do
    for level <- [:level_1a, :level_1c, :level_1d, :graduated] do
      assert PlanSolver.sustainable_ceiling(:navy_seal, level) ==
               BurpeeTrainer.PaceModel.fastest_recommended_sec_per_rep(:navy_seal, level)
    end
  end

  test "navy_seal ceiling is always slower than six_count at same level" do
    for level <- [:level_1a, :level_1c, :level_1d, :level_2, :level_3, :level_4, :graduated] do
      six = PlanSolver.sustainable_ceiling(:six_count, level)
      navy = PlanSolver.sustainable_ceiling(:navy_seal, level)
      assert navy > six, "expected navy_seal ceiling > six_count at #{level}"
    end
  end

  test "default_reps_per_set/1 returns sensible defaults" do
    assert PlanSolver.default_reps_per_set(:six_count) == 10
    assert PlanSolver.default_reps_per_set(:navy_seal) == 5
  end

  test "even solve accepts preferred block pattern" do
    {:ok, sol} =
      PlanSolver.solve(
        input(%{
          pacing_style: :even,
          burpee_type: :navy_seal,
          burpee_count_target: 70,
          target_duration_min: 20,
          block_pattern: [4, 3]
        })
      )

    assert Enum.map(sol.plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [
             [4, 3]
           ]

    assert [%{kind: :block_run, repeat_count: 10}] = sol.plan.steps
  end

  test "rejects non-positive preferred block pattern entries" do
    assert {:error, [msg]} =
             PlanSolver.solve(
               input(%{
                 pacing_style: :even,
                 burpee_count_target: 70,
                 block_pattern: [4, 0]
               })
             )

    assert msg =~ "block pattern"
  end

  test "even solve recommends human-sized repeated sets for high rep targets" do
    {:ok, sol} =
      PlanSolver.solve(
        input(%{
          pacing_style: :even,
          burpee_type: :six_count,
          burpee_count_target: 160,
          target_duration_min: 20,
          level: :level_1a
        })
      )

    assert sol.burpee_count == 160
    assert sol.plan.blocks != []
    refute match?([%{sets: [%{burpee_count: 160}]}], sol.plan.blocks)

    [block | _] = sol.plan.blocks
    assert Enum.all?(block.sets, &(&1.burpee_count in [15, 12, 10, 9, 8, 6, 5, 4]))
    assert [%{kind: :block_run, repeat_count: repeats} | _] = sol.plan.steps
    assert repeats > 1
    assert sol.metadata.set_pattern_strategy in [:smart_even, :preferred_pattern]
  end

  test "solve/1 returns ok with valid rich solution" do
    assert {:ok, %Solution{} = sol} = PlanSolver.solve(input())

    assert is_float(sol.sec_per_burpee)

    assert sol.sec_per_burpee >=
             BurpeeTrainer.PaceModel.fastest_recommended_sec_per_rep(:six_count, :level_1c) -
               1.0e-6

    assert sol.set_count >= 1
    assert sol.set_size >= 1
    assert Enum.sum(sol.set_pattern) == 20
    assert length(sol.rest_pattern_sec) == max(length(sol.set_pattern) - 1, 0)
    assert sol.burpee_count == 20
    assert sol.pacing_style == :even
    assert sol.burpee_type == :six_count
    assert sol.metadata.solver_version == "deterministic-v2"
    assert is_float(sol.duration_sec)
    assert_in_delta sol.duration_sec, 600.0, 5.0
  end

  test "solve/1 is deterministic and does not require an external solver" do
    assert {:ok, %Solution{} = first} = PlanSolver.solve(input())
    assert {:ok, %Solution{} = second} = PlanSolver.solve(input())

    assert first.sec_per_burpee == second.sec_per_burpee
    assert first.set_count == second.set_count
    assert first.rest_sec == second.rest_sec
  end

  test "solver chooses pace >= six_count ceiling for each level" do
    for level <- [:level_1a, :level_1c, :level_2, :level_4] do
      ceiling = PlanSolver.sustainable_ceiling(:six_count, level)
      {:ok, sol} = PlanSolver.solve(input(%{level: level}))

      assert sol.sec_per_burpee >= ceiling - 1.0e-4,
             "level #{level}: expected pace >= #{ceiling}, got #{sol.sec_per_burpee}"
    end
  end

  test "navy_seal solve uses navy_seal ceiling, not six_count" do
    {:ok, sol} =
      PlanSolver.solve(
        input(%{burpee_type: :navy_seal, level: :level_1d, burpee_count_target: 10})
      )

    ceiling = PlanSolver.sustainable_ceiling(:navy_seal, :level_1d)
    assert sol.sec_per_burpee >= ceiling - 1.0e-4
    # Must be well above the six_count ceiling at same level
    six_ceiling = PlanSolver.sustainable_ceiling(:six_count, :level_1d)
    assert sol.sec_per_burpee > six_ceiling
  end

  test "higher level yields faster optimal pace" do
    {:ok, sol_1a} = PlanSolver.solve(input(%{level: :level_1a}))
    {:ok, sol_4} = PlanSolver.solve(input(%{level: :level_4}))
    assert sol_4.sec_per_burpee <= sol_1a.sec_per_burpee
  end

  test "solution execution is canonical for generated plan totals" do
    cases = [
      input(%{pacing_style: :even, burpee_count_target: 160, target_duration_min: 20}),
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 8,
        burpee_count_target: 144,
        target_duration_min: 20
      })
    ]

    for input <- cases do
      assert {:ok, sol} = PlanSolver.solve(input)
      assert_solution_matches_execution(input, sol)
    end
  end

  test "solver grid keeps execution and persisted plan in sync" do
    cases =
      for burpee_type <- [:six_count, :navy_seal],
          {pacing_style, reps_per_set, block_pattern} <- [
            {:even, nil, nil},
            {:even, nil, [8]},
            {:unbroken, 5, nil},
            {:unbroken, 8, nil}
          ],
          {target_duration_min, burpee_count_target} <- [{20, 80}, {20, 120}, {40, 160}] do
        input(%{
          burpee_type: burpee_type,
          pacing_style: pacing_style,
          reps_per_set: reps_per_set,
          block_pattern: block_pattern,
          target_duration_min: target_duration_min,
          burpee_count_target: burpee_count_target,
          level: :level_2
        })
      end

    for input <- cases do
      case PlanSolver.solve(input) do
        {:ok, sol} -> assert_solution_matches_execution(input, sol)
        {:error, reasons} -> assert Enum.all?(reasons, &is_binary/1)
      end
    end
  end

  test "unbroken solve uses MILP to keep short sessions fast with useful recovery" do
    input =
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 8,
        burpee_count_target: 80,
        target_duration_min: 10,
        level: :level_2
      })

    assert {:ok, sol} = PlanSolver.solve(input)
    assert_solution_matches_execution(input, sol)

    assert sol.metadata.set_pattern_strategy == :human_candidate_search

    fastest = BurpeeTrainer.PaceModel.fastest_recommended_sec_per_rep(:six_count, :level_2)
    assert sol.sec_per_burpee >= fastest
    assert sol.sec_per_burpee < 6.0
    assert Enum.all?(sol.rest_pattern_sec, &(&1 == 0.0 or &1 >= 8.0))
    assert Enum.max(sol.rest_pattern_sec) <= 90.0
    assert sol.metadata.rest_suggestions == []
  end

  test "plan solver v3 golden case uses readable taper and exact recovery windows" do
    input =
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 8,
        burpee_count_target: 140,
        target_duration_min: 20,
        level: :level_1a
      })

    assert {:ok, sol} = PlanSolver.solve(input)
    assert_solution_matches_execution(input, sol)

    assert sol.metadata.solver_version == "deterministic-v3"
    assert sol.metadata.set_pattern_strategy == :grammar_search
    assert sol.set_pattern == [8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 6, 7, 6, 7, 6, 7, 6, 7, 6]
    assert Enum.count(sol.rest_pattern_sec, &(&1 == 90.0)) == 2
    assert Enum.count(sol.rest_pattern_sec, &(&1 == 15.0)) == 17
    assert_in_delta sol.sec_per_burpee, 5.464285714, 1.0e-6
  end

  test "plan solver v3 does not use hidden pace-floor relaxation" do
    assert {:error, [_msg]} =
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
  end

  test "unbroken solve with additional rest keeps execution and persisted plan in sync" do
    input =
      input(%{
        pacing_style: :unbroken,
        reps_per_set: 8,
        burpee_count_target: 120,
        target_duration_min: 20,
        level: :level_2,
        additional_rests: [%{target_min: 10, rest_sec: 45}]
      })

    assert {:ok, sol} = PlanSolver.solve(input)
    assert_solution_matches_execution(input, sol)

    rest_steps = Enum.filter(sol.plan.steps, &(&1.kind == :rest))

    assert Enum.any?(rest_steps, &(&1.rest_sec == 45))
    assert Enum.find_index(sol.plan.steps, &(&1.kind == :rest && &1.rest_sec == 45)) > 0
    assert List.last(sol.plan.steps).kind == :block_run
    assert hd(List.last(sol.plan.blocks).sets).end_of_set_rest == 0
  end

  test ":unbroken solve — reusable blocks omit final recovery" do
    {:ok, sol} =
      PlanSolver.solve(input(%{pacing_style: :unbroken, reps_per_set: 5}))

    assert Enum.sum(Enum.map(sol.plan.blocks, & &1.repeat_count)) == 4

    assert Enum.all?(sol.plan.blocks, fn block ->
             [%{burpee_count: 5}] = block.sets
             true
           end)

    assert List.last(sol.plan.blocks).sets |> hd() |> Map.fetch!(:end_of_set_rest) == 0
    assert BurpeeTrainer.Planner.summary(sol.plan).burpee_count_total == sol.burpee_count
    assert round(BurpeeTrainer.Planner.summary(sol.plan).duration_sec_total) == sol.duration_sec
  end

  test "unbroken 160 in 20 minutes with 8 reps per set preserves auto recovery" do
    {:ok, sol} =
      PlanSolver.solve(
        input(%{
          pacing_style: :unbroken,
          burpee_type: :six_count,
          burpee_count_target: 160,
          target_duration_min: 20,
          level: :level_1a,
          reps_per_set: 8
        })
      )

    assert sol.set_pattern == List.duplicate(8, 20)
    assert length(sol.rest_pattern_sec) == 19
    assert sol.rest_sec >= 8.0

    assert sol.sec_per_burpee >= sol.metadata.pace_fastest_sec_per_rep * 0.92
    assert Enum.all?(sol.rest_pattern_sec, &(&1 <= 15.0 or &1 >= 60.0))
    assert Enum.count(sol.rest_pattern_sec, &(&1 >= 60.0)) <= 2
    assert sol.metadata.recovery_mode == :auto
    assert sol.metadata.recommendation =~ "20 × 8"
  end

  test "unbroken rejects repeated sets when recovery would be useless" do
    assert {:error, [_msg]} =
             PlanSolver.solve(
               input(%{
                 pacing_style: :unbroken,
                 burpee_type: :six_count,
                 burpee_count_target: 290,
                 target_duration_min: 20,
                 level: :level_4,
                 reps_per_set: 5
               })
             )
  end

  test "solver explains impossible aggressive prescription with actionable alternatives" do
    assert {:error, [msg]} =
             PlanSolver.solve(
               input(%{
                 pacing_style: :unbroken,
                 burpee_type: :six_count,
                 burpee_count_target: 300,
                 target_duration_min: 20,
                 level: :level_1a,
                 reps_per_set: 8
               })
             )

    assert msg =~ "requires"
    assert msg =~ "Try"
    assert msg =~ "lowering reps"
  end

  test "returns error when work alone exceeds target" do
    assert {:error, [msg]} =
             PlanSolver.solve(input(%{target_duration_min: 1, level: :level_1a}))

    assert is_binary(msg)
  end

  test "solver keeps midpoint reset suggestion available alongside useful auto recovery" do
    {:ok, sol} =
      PlanSolver.solve(
        input(%{
          pacing_style: :unbroken,
          burpee_type: :six_count,
          burpee_count_target: 160,
          target_duration_min: 20,
          level: :level_1a,
          reps_per_set: 8
        })
      )

    assert Enum.all?(sol.plan.steps, &(&1.kind == :block_run))
    assert BurpeeTrainer.Planner.summary(sol.plan).burpee_count_total == 160
    assert round(BurpeeTrainer.Planner.summary(sol.plan).duration_sec_total) == 1200

    assert sol.rest_sec >= 8.0

    assert [%{target_min: target_min, rest_sec: 30, effect: effect}] =
             sol.metadata.rest_suggestions

    assert target_min in 10..16
    assert effect =~ "recovery"
  end

  test "unbroken supports non-uniform human-shaped set patterns for awkward targets" do
    {:ok, sol} =
      PlanSolver.solve(
        input(%{
          pacing_style: :unbroken,
          reps_per_set: 10,
          burpee_count_target: 107,
          target_duration_min: 20,
          level: :level_3
        })
      )

    assert Enum.sum(sol.set_pattern) == 107
    assert Enum.uniq(sol.set_pattern) |> length() > 1
    assert List.last(sol.set_pattern) != 0
    assert Enum.all?(sol.set_pattern, &(&1 in [4, 5, 6, 8, 9, 10, 12, 15]))
    assert sol.metadata.set_pattern_strategy == :human_candidate_search
    assert BurpeeTrainer.Planner.summary(sol.plan).burpee_count_total == 107
    assert_in_delta BurpeeTrainer.Planner.summary(sol.plan).duration_sec_total, 1200.0, 5.0
  end

  test "solution rest pattern excludes final rest" do
    {:ok, sol} =
      PlanSolver.solve(
        input(%{
          pacing_style: :unbroken,
          reps_per_set: 5,
          burpee_count_target: 20,
          target_duration_min: 10
        })
      )

    assert length(sol.set_pattern) == 4
    assert length(sol.rest_pattern_sec) == 3
    assert Enum.sum(Enum.map(sol.plan.blocks, & &1.repeat_count)) == 4
    assert hd(List.first(sol.plan.blocks).sets).end_of_set_rest > 0
    assert hd(List.last(sol.plan.blocks).sets).end_of_set_rest == 0
    assert BurpeeTrainer.Planner.summary(sol.plan).burpee_count_total == 20
    assert round(BurpeeTrainer.Planner.summary(sol.plan).duration_sec_total) == 600
  end

  test "pace model is the source of pace bounds" do
    {:ok, sol} = PlanSolver.solve(input(%{burpee_type: :navy_seal, level: :level_1c}))

    assert_in_delta sol.metadata.pace_fastest_sec_per_rep,
                    BurpeeTrainer.PaceModel.fastest_recommended_sec_per_rep(
                      :navy_seal,
                      :level_1c
                    ),
                    1.0e-6
  end

  test "workout-level ceiling used when tighter: 200 reps at level_1d gets level_2 pace" do
    # 200 six_count reps = level_2 landmark → ceiling 5.0s
    # level_1d ceiling = 5.5s; workout ceiling (5.0) is tighter
    # solver should find p >= 5.0, and there should be meaningful rest
    {:ok, sol} =
      PlanSolver.solve(
        input(%{
          burpee_count_target: 200,
          target_duration_min: 20,
          level: :level_1d,
          pacing_style: :unbroken,
          reps_per_set: 5
        })
      )

    assert sol.sec_per_burpee >=
             BurpeeTrainer.PaceModel.fastest_recommended_sec_per_rep(:six_count, :level_2) -
               1.0e-4

    # With p=5.0: work=1000s, budget=1200s → 200s rest across 39 gaps ≈ 5s/gap
    assert sol.rest_sec > 0
  end

  test "pace override pins the solver to the given pace" do
    {:ok, sol} =
      PlanSolver.solve(
        input(%{
          burpee_count_target: 50,
          target_duration_min: 10,
          sec_per_burpee_override: 7.0
        })
      )

    assert_in_delta sol.sec_per_burpee, 7.0, 1.0e-3
  end

  test "unbroken one-rep target with leftover additional rest returns an error instead of crashing" do
    assert {:error, [msg]} =
             PlanSolver.solve(
               input(%{
                 pacing_style: :unbroken,
                 reps_per_set: 8,
                 burpee_count_target: 1,
                 target_duration_min: 20,
                 additional_rests: [%{rest_sec: 30, target_min: 12}]
               })
             )

    assert msg =~ "Rest at minute 12"
  end

  test "additional_rests places rest within 30s of target" do
    inp =
      input(%{
        burpee_count_target: 20,
        target_duration_min: 10,
        additional_rests: [%{rest_sec: 60, target_min: 5}]
      })

    {:ok, sol} = PlanSolver.solve(inp)
    assert Enum.map(sol.plan.steps, & &1.kind) == [:block_run, :rest, :block_run]
    assert Enum.at(sol.plan.steps, 1).rest_sec == 60
  end

  defp assert_solution_matches_execution(input, sol) do
    summary = BurpeeTrainer.Planner.summary(sol.plan)

    assert BurpeeTrainer.PlanSolver.Execution.burpee_count(sol.execution) ==
             summary.burpee_count_total

    assert_in_delta BurpeeTrainer.PlanSolver.Execution.duration_sec(sol.execution),
                    summary.duration_sec_total,
                    1.0

    assert summary.burpee_count_total == input.burpee_count_target
    assert_in_delta summary.duration_sec_total, input.target_duration_min * 60.0, 5.0
  end
end
