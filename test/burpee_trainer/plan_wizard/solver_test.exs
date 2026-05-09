defmodule BurpeeTrainer.PlanWizard.SolverTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{PlanInput, SlotModel, Solver}

  defp input(overrides) do
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

  defp sum_total(%SlotModel{} = m) do
    work = SlotModel.work_sec(m)
    rest = Enum.sum(m.slot_rests)
    reserved = Enum.reduce(m.reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    work + rest + reserved
  end

  describe "solve/2 — :even no rests" do
    test "uniformly distributes the rest budget across all slots" do
      assert {:ok, %SlotModel{} = m} = Solver.solve(input(%{}))
      assert length(m.slot_rests) == 99
      # 1200 - 500 = 700 budget, spread across 99 slots
      expected = 700.0 / 99
      assert Enum.all?(m.slot_rests, fn r -> abs(r - expected) < 1.0e-9 end)
      assert_in_delta sum_total(m), 1200, 1.0
    end
  end

  describe "solve/2 — :even with reservations" do
    test "reserved slots get exact rest, others share remaining budget" do
      rests = [%{rest_sec: 60, target_min: 5}, %{rest_sec: 60, target_min: 10}]
      assert {:ok, %SlotModel{} = m} = Solver.solve(input(%{additional_rests: rests}))

      assert length(m.reservations) == 2
      reserved_slots = MapSet.new(m.reservations, & &1.slot)

      reserved_rests =
        m.slot_rests
        |> Enum.with_index(1)
        |> Enum.filter(fn {_r, i} -> MapSet.member?(reserved_slots, i) end)
        |> Enum.map(fn {r, _} -> r end)

      assert Enum.sort(reserved_rests) == [60.0, 60.0]
      assert_in_delta sum_total(m), 1200, 1.0
    end
  end

  describe "solve/2 — :unbroken no rests" do
    test "concentrates rest at set boundaries; intra-set slots get 0" do
      assert {:ok, %SlotModel{} = m} =
               Solver.solve(input(%{pacing_style: :unbroken, burpee_count_target: 50}), 10)

      # 50 reps, 10/set → boundary slots at 10, 20, 30, 40
      boundary_slots = [10, 20, 30, 40]

      m.slot_rests
      |> Enum.with_index(1)
      |> Enum.each(fn {rest, i} ->
        if i in boundary_slots do
          assert rest > 0.0
        else
          assert rest == 0.0
        end
      end)

      assert_in_delta sum_total(m), 1200, 1.0
    end
  end

  describe "solve/2 — :unbroken with reservations" do
    test "reserved boundary slots get exact rest_sec, remaining spread on other boundaries" do
      # 50 reps, 10/set → boundaries at slots 10/20/30/40
      # budget = 1200 − 250 − 60 = 890, /4 ≈ 222.5/gap
      # slot 10 time = 50 + 222.5 = 272.5s ≈ 4.54 min — within 30s of target 5 min
      rests = [%{rest_sec: 60, target_min: 5}]

      assert {:ok, %SlotModel{} = m} =
               Solver.solve(
                 input(%{
                   pacing_style: :unbroken,
                   burpee_count_target: 50,
                   additional_rests: rests
                 }),
                 10
               )

      [r] = m.reservations
      reserved_rest = Enum.at(m.slot_rests, r.slot - 1)
      assert reserved_rest == 60.0
      assert_in_delta sum_total(m), 1200, 1.0
    end
  end

  describe "solve/2 — pace too fast" do
    test "rejects sec_per_burpee below the burpee-type floor" do
      assert {:error, [msg]} = Solver.solve(input(%{sec_per_burpee: 2.0}))
      assert msg =~ "below the minimum"
      assert msg =~ "graduation pace floor"
    end
  end

  describe "solve/2 — work exceeds target" do
    test "errors when total work alone exceeds target duration" do
      assert {:error, [msg]} =
               Solver.solve(input(%{target_duration_min: 5, burpee_count_target: 100}))

      assert msg =~ "work time"
      assert msg =~ "exceeds target duration"
    end
  end

  describe "solve/2 — :even rest exceeds pace floor" do
    test "errors when additional rests force shaved cadence below sec_per_burpee" do
      # 100 reps × 5s = 500s work; 1200s target → 700s budget
      # Add 800s of rest → budget exhausted, cadence drops below 5s
      rests = [%{rest_sec: 800, target_min: 10}]

      assert {:error, [msg]} = Solver.solve(input(%{additional_rests: rests}))
      assert msg =~ "total additional rest"
      assert msg =~ "rep floor"
    end
  end

  describe "solve/2 — :unbroken work + rests exceed target" do
    test "errors when work + additional rests exceed target" do
      # 50 × 5 = 250s work; target 5min = 300s; 100s rest → 350 > 300
      rests = [%{rest_sec: 100, target_min: 1}]

      assert {:error, [msg]} =
               Solver.solve(
                 input(%{
                   pacing_style: :unbroken,
                   burpee_count_target: 50,
                   target_duration_min: 5,
                   additional_rests: rests
                 }),
                 10
               )

      assert msg =~ "exceeds target duration"
    end
  end

  describe "solve/2 — total duration constraint" do
    test "ok plans always satisfy work + rest + reserved ≈ target" do
      cases = [
        {%{}, nil},
        {%{additional_rests: [%{rest_sec: 60, target_min: 10}]}, nil},
        {%{pacing_style: :unbroken, burpee_count_target: 30}, 5},
        {%{
           pacing_style: :unbroken,
           burpee_count_target: 50,
           additional_rests: [%{rest_sec: 45, target_min: 5}]
         }, 10}
      ]

      for {overrides, rps} <- cases do
        {:ok, m} = Solver.solve(input(overrides), rps)
        assert_in_delta sum_total(m), m.target_duration_sec, 1.0
      end
    end
  end
end
