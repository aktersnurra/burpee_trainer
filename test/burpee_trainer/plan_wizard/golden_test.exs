defmodule BurpeeTrainer.PlanWizard.GoldenTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard
  alias BurpeeTrainer.Workouts.{Block, Set}

  @golden Code.eval_file("test/fixtures/planner_golden.exs") |> elem(0)

  for {fixture, idx} <- Enum.with_index(@golden) do
    @fixture fixture
    @tag fixture: idx
    test "golden: #{fixture.name}" do
      assert {:ok, plan} = PlanWizard.generate(@fixture.input)

      sets = Enum.flat_map(plan.blocks, fn %Block{sets: sets} -> sets end)
      total_reps = Enum.reduce(sets, 0, fn %Set{burpee_count: c}, acc -> acc + c end)

      duration =
        Enum.reduce(sets, 0, fn %Set{burpee_count: c, sec_per_rep: spr, end_of_set_rest: r},
                                acc ->
          acc + c * spr + r
        end)

      assert length(plan.blocks) == @fixture.expect.block_count
      assert length(sets) == @fixture.expect.total_sets
      assert total_reps == @fixture.expect.total_reps
      assert_in_delta duration, @fixture.expect.duration_sec, 1.0
    end
  end
end
