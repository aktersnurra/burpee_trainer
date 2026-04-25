defmodule BurpeeTrainer.PlanWizardTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard
  alias BurpeeTrainer.PlanWizard.WizardInput

  defp input(overrides \\ %{}) do
    base = %WizardInput{
      duration_sec_total: 1200,
      burpee_type: :six_count,
      burpee_count_total: 100,
      sec_per_burpee: 5.0,
      pacing_style: :even
    }

    Map.merge(base, overrides)
  end

  defp total_burpees(plan) do
    Enum.sum(
      for b <- plan.blocks, s <- b.sets, do: s.burpee_count * b.repeat_count
    )
  end

  defp total_work_sec(plan) do
    Enum.sum(
      for b <- plan.blocks, s <- b.sets, do: s.burpee_count * s.sec_per_rep * b.repeat_count
    )
  end

  # ---------------------------------------------------------------------------
  # validate/1
  # ---------------------------------------------------------------------------

  describe "validate/1" do
    test "returns :ok for valid input" do
      assert PlanWizard.validate(input()) == :ok
    end

    test "error when work_sec exceeds total duration" do
      {:error, reasons} = PlanWizard.validate(input(%{sec_per_burpee: 15.0}))
      assert Enum.any?(reasons, &String.contains?(&1, "exceeds"))
    end

    test "error when burpee_count_total is zero" do
      {:error, reasons} = PlanWizard.validate(input(%{burpee_count_total: 0}))
      assert Enum.any?(reasons, &String.contains?(&1, "burpee_count_total"))
    end

    test "error when burpee_count_total is negative" do
      {:error, reasons} = PlanWizard.validate(input(%{burpee_count_total: -5}))
      assert Enum.any?(reasons, &String.contains?(&1, "burpee_count_total"))
    end

    test "error when duration_sec_total is zero" do
      {:error, reasons} = PlanWizard.validate(input(%{duration_sec_total: 0}))
      assert Enum.any?(reasons, &String.contains?(&1, "duration_sec_total"))
    end

    test "multiple errors are collected" do
      {:error, reasons} = PlanWizard.validate(input(%{burpee_count_total: 0, duration_sec_total: 0}))
      assert length(reasons) >= 2
    end
  end

  # ---------------------------------------------------------------------------
  # generate/1 — even pacing
  # ---------------------------------------------------------------------------

  describe "generate/1 — even pacing" do
    test "total burpee count matches input" do
      {:ok, plan} = PlanWizard.generate(input())
      assert total_burpees(plan) == 100
    end

    test "uses repeat_count optimisation for clean divisor (100 / 10 = 10)" do
      {:ok, plan} = PlanWizard.generate(input(%{burpee_count_total: 100}))
      assert length(plan.blocks) == 1
      [block] = plan.blocks
      assert length(block.sets) == 1
      assert block.repeat_count == 10
      assert hd(block.sets).burpee_count == 10
    end

    test "falls back to multiple sets when not evenly divisible" do
      {:ok, plan} = PlanWizard.generate(input(%{burpee_count_total: 17}))
      assert total_burpees(plan) == 17
    end

    test "work time does not exceed total duration" do
      {:ok, plan} = PlanWizard.generate(input())
      assert total_work_sec(plan) <= 1200
    end

    test "sec_per_burpee satisfies sec_per_burpee <= sec_per_rep" do
      {:ok, plan} = PlanWizard.generate(input())
      for b <- plan.blocks, s <- b.sets do
        assert s.sec_per_burpee <= s.sec_per_rep
      end
    end

    test "navy_seal uses smaller default set size" do
      {:ok, plan} = PlanWizard.generate(input(%{burpee_type: :navy_seal}))
      [block] = plan.blocks
      # target_set_size = 5, so 100 / 5 = 20 sets
      assert block.repeat_count == 20
      assert hd(block.sets).burpee_count == 5
    end
  end

  # ---------------------------------------------------------------------------
  # generate/1 — unbroken pacing
  # ---------------------------------------------------------------------------

  describe "generate/1 — unbroken pacing" do
    test "total burpee count matches input" do
      {:ok, plan} = PlanWizard.generate(input(%{pacing_style: :unbroken}))
      assert total_burpees(plan) == 100
    end

    test "produces one block with repeat_count 1" do
      {:ok, plan} = PlanWizard.generate(input(%{pacing_style: :unbroken}))
      assert length(plan.blocks) == 1
      assert hd(plan.blocks).repeat_count == 1
    end

    test "intra-group sets have micro rest (4s)" do
      {:ok, plan} = PlanWizard.generate(input(%{pacing_style: :unbroken}))
      [block] = plan.blocks
      # At least one non-boundary set should have the micro rest
      assert Enum.any?(block.sets, fn s -> s.end_of_set_rest == 4 end)
    end

    test "group-boundary sets have longer rest than micro rest" do
      {:ok, plan} = PlanWizard.generate(input(%{pacing_style: :unbroken}))
      [block] = plan.blocks
      assert Enum.any?(block.sets, fn s -> s.end_of_set_rest > 4 end)
    end

    test "work time does not exceed total duration" do
      {:ok, plan} = PlanWizard.generate(input(%{pacing_style: :unbroken}))
      assert total_work_sec(plan) <= 1200
    end
  end

  # ---------------------------------------------------------------------------
  # generate/1 — extra rest
  # ---------------------------------------------------------------------------

  # at_sec: 600 = 5 * time_per_repeat (10 reps * 12s cadence = 120s/repeat)
  # → after_block = 5, same split as the old after_block: 5 test
  describe "generate/1 — extra rest (even pacing)" do
    test "splits a repeating block into two at the closest boundary" do
      extra = %{at_sec: 600, rest_sec: 120}
      {:ok, plan} = PlanWizard.generate(input(%{extra_rest: extra}))
      assert length(plan.blocks) == 2
      [b1, b2] = plan.blocks
      assert b1.repeat_count == 5
      assert b2.repeat_count == 5
    end

    test "last set of block 1 gets the extra rest" do
      extra = %{at_sec: 600, rest_sec: 120}
      {:ok, plan} = PlanWizard.generate(input(%{extra_rest: extra}))
      [first | _] = plan.blocks
      last_set = List.last(first.sets)
      assert last_set.end_of_set_rest == 120
    end

    test "total burpee count unchanged after split" do
      extra = %{at_sec: 600, rest_sec: 120}
      {:ok, plan} = PlanWizard.generate(input(%{extra_rest: extra}))
      assert total_burpees(plan) == 100
    end

    test "total duration stays within target" do
      extra = %{at_sec: 600, rest_sec: 120}
      {:ok, plan} = PlanWizard.generate(input(%{extra_rest: extra}))

      total =
        Enum.sum(
          for b <- plan.blocks, s <- b.sets,
              do: (s.burpee_count * s.sec_per_rep + s.end_of_set_rest) * b.repeat_count
        )

      assert_in_delta total, 1200.0, 1.0
    end

    test "error when extra rest would push cadence below sec_per_burpee floor" do
      # sec_per_burpee=11, base_cadence=12; after_block=5 → shave=600s, floor violated
      extra = %{at_sec: 600, rest_sec: 120}
      assert {:error, [msg]} = PlanWizard.generate(input(%{sec_per_burpee: 11.0, extra_rest: extra}))
      assert String.contains?(msg, "floor")
    end
  end

  describe "generate/1 — extra rest (unbroken pacing)" do
    test "total duration stays within target" do
      extra = %{at_sec: 600, rest_sec: 30}

      {:ok, plan} =
        PlanWizard.generate(input(%{pacing_style: :unbroken, extra_rest: extra}))

      total =
        Enum.sum(
          for b <- plan.blocks, s <- b.sets,
              do: (s.burpee_count * s.sec_per_rep + s.end_of_set_rest) * b.repeat_count
        )

      assert_in_delta total, 1200.0, 2.0
    end

    test "splits into two blocks" do
      extra = %{at_sec: 600, rest_sec: 30}
      {:ok, plan} = PlanWizard.generate(input(%{pacing_style: :unbroken, extra_rest: extra}))
      assert length(plan.blocks) == 2
    end

    test "error when extra rest exceeds available rest budget" do
      # Large extra_rest that exhausts the entire rest budget
      extra = %{at_sec: 600, rest_sec: 800}
      assert {:error, [msg]} = PlanWizard.generate(input(%{pacing_style: :unbroken, extra_rest: extra}))
      assert String.contains?(msg, "budget")
    end
  end

  # ---------------------------------------------------------------------------
  # error cases
  # ---------------------------------------------------------------------------

  test "generate returns error for zero burpees" do
    assert {:error, _} = PlanWizard.generate(input(%{burpee_count_total: 0}))
  end

  test "generate returns error when work exceeds duration" do
    assert {:error, _} = PlanWizard.generate(input(%{sec_per_burpee: 20.0}))
  end
end
