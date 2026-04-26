defmodule BurpeeTrainer.PlanWizardTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard
  alias BurpeeTrainer.PlanWizard.PlanInput

  defp input(overrides \\ %{}) do
    base = %PlanInput{
      name: "Test plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      sec_per_burpee: 5.0,
      pacing_style: :even,
      reps_per_set: nil
    }

    struct!(base, overrides)
  end

  defp total_burpees(plan) do
    Enum.sum(for b <- plan.blocks, s <- b.sets, do: s.burpee_count * b.repeat_count)
  end

  defp total_duration(plan) do
    Enum.sum(
      for b <- plan.blocks,
          s <- b.sets,
          do: (s.burpee_count * s.sec_per_rep + s.end_of_set_rest) * b.repeat_count
    )
  end

  # ---------------------------------------------------------------------------
  # validate_pace/2
  # ---------------------------------------------------------------------------

  describe "validate_pace/2" do
    test "accepts pace at exactly the floor for six_count" do
      floor = Float.ceil(1200 / 325, 2)
      assert PlanWizard.validate_pace(:six_count, floor) == :ok
    end

    test "accepts pace at exactly the floor for navy_seal" do
      assert PlanWizard.validate_pace(:navy_seal, 8.0) == :ok
    end

    test "rejects pace below floor for six_count" do
      assert {:error, :pace_too_fast, _floor} = PlanWizard.validate_pace(:six_count, 1.0)
    end

    test "rejects pace below floor for navy_seal" do
      assert {:error, :pace_too_fast, 8.0} = PlanWizard.validate_pace(:navy_seal, 7.9)
    end
  end

  # ---------------------------------------------------------------------------
  # generate/1 — even pacing (uniform inter-rep cadence)
  # ---------------------------------------------------------------------------

  describe "generate/1 — even pacing" do
    test "total burpee count matches input" do
      {:ok, plan} = PlanWizard.generate(input())
      assert total_burpees(plan) == 100
    end

    test "produces a single set with all reps and no trailing rest" do
      {:ok, plan} = PlanWizard.generate(input())
      assert length(plan.blocks) == 1
      [block] = plan.blocks
      assert length(block.sets) == 1
      [set] = block.sets
      assert set.burpee_count == 100
      assert set.end_of_set_rest == 0
    end

    test "sec_per_rep is uniform cadence (target_duration / total_reps)" do
      {:ok, plan} = PlanWizard.generate(input())
      [set] = hd(plan.blocks).sets
      expected_cadence = 20 * 60 / 100
      assert_in_delta set.sec_per_rep, expected_cadence, 0.001
    end

    test "sec_per_rep > sec_per_burpee (rest absorbed into cadence)" do
      {:ok, plan} = PlanWizard.generate(input())
      [set] = hd(plan.blocks).sets
      assert set.sec_per_rep > set.sec_per_burpee
    end

    test "duration equals target exactly" do
      {:ok, plan} = PlanWizard.generate(input())
      assert_in_delta total_duration(plan), 20 * 60, 0.001
    end

    test "error when pace is below six_count floor" do
      assert {:error, [msg]} = PlanWizard.generate(input(sec_per_burpee: 1.0))
      assert String.contains?(msg, "floor")
    end

    test "error when work time exceeds target duration" do
      assert {:error, [msg]} = PlanWizard.generate(input(sec_per_burpee: 20.0))
      assert String.contains?(msg, "exceeds")
    end
  end

  # ---------------------------------------------------------------------------
  # generate/1 — unbroken pacing
  # ---------------------------------------------------------------------------

  describe "generate/1 — unbroken pacing" do
    test "produces multiple sets of reps_per_set with rest between them" do
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken, reps_per_set: 10))
      [block] = plan.blocks
      # 100 reps / 10 per set = 10 sets
      assert length(block.sets) == 10
      assert Enum.all?(block.sets |> Enum.take(9), fn s -> s.burpee_count == 10 end)
    end

    test "total burpee count matches input" do
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken, reps_per_set: 10))
      assert total_burpees(plan) == 100
    end

    test "duration is within ±5s of target" do
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken, reps_per_set: 10))
      assert abs(total_duration(plan) - 1200) <= 5
    end

    test "last set has no trailing rest" do
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken, reps_per_set: 10))
      last_set = plan.blocks |> hd() |> Map.get(:sets) |> List.last()
      assert last_set.end_of_set_rest == 0
    end

    test "sec_per_rep == sec_per_burpee for all sets" do
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken, reps_per_set: 10))
      for b <- plan.blocks, s <- b.sets do
        assert_in_delta s.sec_per_rep, s.sec_per_burpee, 0.001
      end
    end

    test "partial last set when total is not evenly divisible" do
      # 102 reps / 10 per set = 10 full + 2 remainder
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken, burpee_count_target: 102, reps_per_set: 10))
      [block] = plan.blocks
      assert length(block.sets) == 11
      last_set = List.last(block.sets)
      assert last_set.burpee_count == 2
    end

    test "reps_per_set larger than total produces one set" do
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken, reps_per_set: 200))
      [block] = plan.blocks
      assert length(block.sets) == 1
      assert hd(block.sets).burpee_count == 100
    end

    test "default reps_per_set is 10 for six_count" do
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken))
      [block] = plan.blocks
      assert length(block.sets) == 10
    end

    test "default reps_per_set is 5 for navy_seal" do
      {:ok, plan} = PlanWizard.generate(input(pacing_style: :unbroken, burpee_type: :navy_seal, sec_per_burpee: 9.0))
      [block] = plan.blocks
      # 100 reps / 5 per set = 20 sets
      assert length(block.sets) == 20
    end

    test "additional rests supported for unbroken" do
      # 10 sets of 10 reps, each set boundary at ~120s intervals
      # at_min 10 = 600s — should land on boundary 5
      {:ok, plan} =
        PlanWizard.generate(
          input(pacing_style: :unbroken, reps_per_set: 10,
                additional_rests: [%{rest_sec: 30, target_min: 10}])
        )
      assert total_burpees(plan) == 100
    end
  end

  # ---------------------------------------------------------------------------
  # generate/1 — additional rests (even pacing)
  # ---------------------------------------------------------------------------

  describe "generate/1 — additional rests (even pacing)" do
    test "rest injected at target minute, total burpees unchanged" do
      {:ok, plan} =
        PlanWizard.generate(input(additional_rests: [%{rest_sec: 30, target_min: 10}]))

      assert total_burpees(plan) == 100
    end

    test "total duration equals target (rest compensated by shaved cadence)" do
      {:ok, plan} =
        PlanWizard.generate(input(additional_rests: [%{rest_sec: 30, target_min: 10}]))

      assert_in_delta total_duration(plan), 20 * 60, 0.1
    end

    test "splits into two blocks around the rest point" do
      {:ok, plan} =
        PlanWizard.generate(input(additional_rests: [%{rest_sec: 30, target_min: 10}]))

      assert length(plan.blocks) == 2
    end

    test "last set of last block has no trailing rest" do
      {:ok, plan} =
        PlanWizard.generate(input(additional_rests: [%{rest_sec: 30, target_min: 10}]))

      last_set = plan.blocks |> List.last() |> Map.get(:sets) |> List.last()
      assert last_set.end_of_set_rest == 0
    end

    test "error when total additional rest exceeds cadence floor budget" do
      # base_cadence = 1200/100 = 12s. sec_per_burpee = 5s. budget = (12-5)*100 = 700s.
      assert {:error, [msg]} =
               PlanWizard.generate(input(additional_rests: [%{rest_sec: 800, target_min: 10}]))

      assert String.contains?(msg, "floor")
    end
  end
end
