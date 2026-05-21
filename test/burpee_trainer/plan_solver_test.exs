defmodule BurpeeTrainer.PlanSolverTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.{Input, Solution}

  @moduletag :highs

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

  test "sustainable_ceiling/1 returns correct ceiling per level" do
    assert PlanSolver.sustainable_ceiling(:level_1a) == 8.0
    assert PlanSolver.sustainable_ceiling(:level_1c) == 6.0
    assert PlanSolver.sustainable_ceiling(:level_4) == 4.0
    assert PlanSolver.sustainable_ceiling(:graduated) == 3.70
  end

  test "default_reps_per_set/1 returns sensible defaults" do
    assert PlanSolver.default_reps_per_set(:six_count) == 10
    assert PlanSolver.default_reps_per_set(:navy_seal) == 5
  end

  test "solve/1 returns ok with valid solution" do
    assert {:ok, %Solution{} = sol} = PlanSolver.solve(input())

    assert is_float(sol.sec_per_burpee)
    assert sol.sec_per_burpee >= 6.0 - 1.0e-6
    assert sol.set_count >= 1
    assert sol.set_size >= 1
    assert sol.set_size * sol.set_count == 20
    assert is_float(sol.duration_sec)
    assert_in_delta sol.duration_sec, 600.0, 5.0
  end

  test "solver chooses pace >= ceiling for each level" do
    for {level, ceiling} <- [
          level_1a: 8.0,
          level_1c: 6.0,
          level_2: 5.0,
          level_4: 4.0
        ] do
      {:ok, sol} = PlanSolver.solve(input(%{level: level}))

      assert sol.sec_per_burpee >= ceiling - 1.0e-4,
             "level #{level}: expected pace >= #{ceiling}, got #{sol.sec_per_burpee}"
    end
  end

  test "higher level yields faster optimal pace" do
    {:ok, sol_1a} = PlanSolver.solve(input(%{level: :level_1a}))
    {:ok, sol_4} = PlanSolver.solve(input(%{level: :level_4}))
    assert sol_4.sec_per_burpee <= sol_1a.sec_per_burpee
  end

  test ":unbroken solve — one block, set_size respected" do
    {:ok, sol} =
      PlanSolver.solve(input(%{pacing_style: :unbroken, reps_per_set: 5}))

    sets = List.first(sol.plan.blocks).sets
    assert length(sets) == 4
    Enum.each(sets, &assert(&1.burpee_count == 5))
  end

  test "returns error when work alone exceeds target" do
    assert {:error, [msg]} =
             PlanSolver.solve(input(%{target_duration_min: 1, level: :level_1a}))

    assert is_binary(msg)
  end

  test "additional_rests places rest within 30s of target" do
    inp =
      input(%{
        burpee_count_target: 20,
        target_duration_min: 10,
        additional_rests: [%{rest_sec: 60, target_min: 5}]
      })

    {:ok, sol} = PlanSolver.solve(inp)
    assert length(sol.plan.blocks) == 2
  end
end
