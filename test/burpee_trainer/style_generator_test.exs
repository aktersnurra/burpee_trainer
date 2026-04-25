defmodule BurpeeTrainer.StyleGeneratorTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.StyleGenerator
  alias BurpeeTrainer.Progression.Recommendation

  defp rec(overrides \\ %{}) do
    Map.merge(
      %Recommendation{
        goal_id: nil,
        burpee_type: :six_count,
        phase: :build_2,
        trend_status: :on_track,
        burpee_count_suggested: 100,
        duration_sec_suggested: 1200,
        sec_per_rep_suggested: 5.0,
        rationale: "Test",
        weeks_remaining: 4,
        burpee_count_projected_at_goal: nil
      },
      overrides
    )
  end

  defp total_burpees(plan) do
    Enum.sum(for b <- plan.blocks, s <- b.sets, do: s.burpee_count * b.repeat_count)
  end

  defp all_sets(plan), do: for(b <- plan.blocks, s <- b.sets, do: s)

  for style <- [:long_sets, :burst, :pyramid, :ladder_up, :even] do
    test "#{style} (6-count): total burpees match recommendation" do
      plan = StyleGenerator.generate(unquote(style), rec())
      assert total_burpees(plan) == 100
    end

    test "#{style} (6-count): sec_per_burpee <= sec_per_rep on all sets" do
      plan = StyleGenerator.generate(unquote(style), rec())
      for s <- all_sets(plan), do: assert(s.sec_per_burpee <= s.sec_per_rep)
    end

    test "#{style} (6-count): last set has zero trailing rest" do
      plan = StyleGenerator.generate(unquote(style), rec())
      [block] = plan.blocks
      assert List.last(block.sets).end_of_set_rest == 0
    end
  end

  for style <- [:even_spaced, :front_loaded, :descending, :minute_on] do
    test "#{style} (navy_seal): total burpees match recommendation" do
      plan = StyleGenerator.generate(unquote(style), rec(%{burpee_type: :navy_seal}))
      assert total_burpees(plan) == 100
    end
  end

  describe "structural properties" do
    test "pyramid has more sets than a single max, with increasing then decreasing counts" do
      plan = StyleGenerator.generate(:pyramid, rec())
      [block] = plan.blocks
      counts = Enum.map(block.sets, & &1.burpee_count)
      max_idx = Enum.find_index(counts, &(&1 == Enum.max(counts)))
      # max should not be the first or last (it's a proper pyramid)
      assert max_idx > 0
      assert max_idx < length(counts) - 1
    end

    test "ladder_up has non-decreasing set sizes" do
      plan = StyleGenerator.generate(:ladder_up, rec())
      [block] = plan.blocks
      counts = Enum.map(block.sets, & &1.burpee_count)
      assert counts == Enum.sort(counts)
    end

    test "descending has non-increasing set sizes" do
      plan = StyleGenerator.generate(:descending, rec(%{burpee_type: :navy_seal}))
      [block] = plan.blocks
      counts = Enum.map(block.sets, & &1.burpee_count)
      assert counts == Enum.sort(counts, :desc)
    end

    test "long_sets has fewer sets than burst for same total" do
      long_plan = StyleGenerator.generate(:long_sets, rec())
      burst_plan = StyleGenerator.generate(:burst, rec())
      [long_block] = long_plan.blocks
      [burst_block] = burst_plan.blocks
      assert length(long_block.sets) < length(burst_block.sets)
    end
  end
end
