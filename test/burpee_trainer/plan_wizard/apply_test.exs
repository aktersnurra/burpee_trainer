defmodule BurpeeTrainer.PlanWizard.ApplyTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{Apply, PlanInput, Solver}
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

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

  defp run(overrides, reps_per_set \\ nil) do
    inp = input(overrides)
    {:ok, model} = Solver.solve(inp, reps_per_set)
    {:ok, plan} = Apply.to_workout_plan(model, inp)
    {plan, inp}
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
  # :even × no reservations
  # ---------------------------------------------------------------------------

  describe ":even, no reservations" do
    test "single block, single set with all reps" do
      {plan, _} = run(%{})
      assert %WorkoutPlan{blocks: [%Block{position: 1, repeat_count: 1, sets: [set]}]} = plan
      assert %Set{position: 1, burpee_count: 100, end_of_set_rest: 0} = set
    end

    test "sec_per_rep equals target / total_reps exactly" do
      {plan, _} = run(%{})
      [%Block{sets: [set]}] = plan.blocks
      assert_in_delta set.sec_per_rep, 12.0, 1.0e-9
    end

    test "duration equals target exactly" do
      {plan, _} = run(%{})
      assert_in_delta total_duration(plan), 1200, 1.0e-6
    end

    test "additional_rests serialised as []" do
      {plan, _} = run(%{})
      assert plan.additional_rests == "[]"
    end
  end

  # ---------------------------------------------------------------------------
  # :even × 1 reservation
  # ---------------------------------------------------------------------------

  describe ":even, 1 reservation" do
    test "splits into two blocks around the reservation" do
      {plan, _} = run(%{additional_rests: [%{rest_sec: 30, target_min: 10}]})
      assert length(plan.blocks) == 2
    end

    test "non-final block carries end_of_set_rest = reservation rest_sec" do
      {plan, _} = run(%{additional_rests: [%{rest_sec: 30, target_min: 10}]})
      [b1, b2] = plan.blocks
      [s1] = b1.sets
      [s2] = b2.sets
      assert s1.end_of_set_rest == 30
      assert s2.end_of_set_rest == 0
    end

    test "burpee counts across blocks sum to total" do
      {plan, _} = run(%{additional_rests: [%{rest_sec: 30, target_min: 10}]})
      assert total_burpees(plan) == 100
    end

    test "uniform shaved cadence across blocks" do
      {plan, _} = run(%{additional_rests: [%{rest_sec: 30, target_min: 10}]})
      cadences = for b <- plan.blocks, s <- b.sets, do: s.sec_per_rep
      [c | rest] = cadences
      assert Enum.all?(rest, fn other -> abs(other - c) < 1.0e-9 end)
      # (1200 − 30) / 100 = 11.7
      assert_in_delta c, 11.7, 1.0e-9
    end

    test "total duration within ±0.1s of target" do
      {plan, _} = run(%{additional_rests: [%{rest_sec: 30, target_min: 10}]})
      assert_in_delta total_duration(plan), 1200, 0.1
    end
  end

  # ---------------------------------------------------------------------------
  # :even × 2 reservations
  # ---------------------------------------------------------------------------

  describe ":even, 2 reservations" do
    test "produces N+1 blocks and last has rest 0" do
      {plan, _} =
        run(%{
          additional_rests: [
            %{rest_sec: 30, target_min: 5},
            %{rest_sec: 60, target_min: 15}
          ]
        })

      assert length(plan.blocks) == 3
      last_set = plan.blocks |> List.last() |> Map.get(:sets) |> List.last()
      assert last_set.end_of_set_rest == 0
    end

    test "each non-final block carries its reservation rest" do
      {plan, _} =
        run(%{
          additional_rests: [
            %{rest_sec: 30, target_min: 5},
            %{rest_sec: 60, target_min: 15}
          ]
        })

      [b1, b2, _b3] = plan.blocks
      assert hd(b1.sets).end_of_set_rest == 30
      assert hd(b2.sets).end_of_set_rest == 60
    end

    test "total burpees match input" do
      {plan, _} =
        run(%{
          additional_rests: [
            %{rest_sec: 30, target_min: 5},
            %{rest_sec: 60, target_min: 15}
          ]
        })

      assert total_burpees(plan) == 100
    end

    test "total duration within ±0.1s of target" do
      {plan, _} =
        run(%{
          additional_rests: [
            %{rest_sec: 30, target_min: 5},
            %{rest_sec: 60, target_min: 15}
          ]
        })

      assert_in_delta total_duration(plan), 1200, 0.1
    end
  end

  # ---------------------------------------------------------------------------
  # :unbroken × no reservations × divisible
  # ---------------------------------------------------------------------------

  describe ":unbroken, no reservations, divisible" do
    test "produces set_count sets of reps_per_set" do
      {plan, _} = run(%{pacing_style: :unbroken}, 10)
      [%Block{sets: sets}] = plan.blocks
      assert length(sets) == 10
      assert Enum.all?(Enum.take(sets, 9), fn s -> s.burpee_count == 10 end)
    end

    test "sec_per_rep == sec_per_burpee for all sets" do
      {plan, _} = run(%{pacing_style: :unbroken}, 10)
      [%Block{sets: sets}] = plan.blocks
      assert Enum.all?(sets, fn s -> s.sec_per_rep == s.sec_per_burpee end)
    end

    test "last set has zero rest, others equal rest_per_gap" do
      {plan, _} = run(%{pacing_style: :unbroken}, 10)
      [%Block{sets: sets}] = plan.blocks
      last = List.last(sets)
      others = Enum.take(sets, length(sets) - 1)
      assert last.end_of_set_rest == 0
      [r | rest] = Enum.map(others, & &1.end_of_set_rest)
      assert Enum.all?(rest, &(&1 == r))
    end

    test "duration within ±5s of target" do
      {plan, _} = run(%{pacing_style: :unbroken}, 10)
      assert abs(total_duration(plan) - 1200) <= 5
    end
  end

  # ---------------------------------------------------------------------------
  # :unbroken × no reservations × non-divisible
  # ---------------------------------------------------------------------------

  describe ":unbroken, no reservations, non-divisible" do
    test "last set is partial; total reps match" do
      {plan, _} = run(%{pacing_style: :unbroken, burpee_count_target: 102}, 10)
      [%Block{sets: sets}] = plan.blocks
      assert length(sets) == 11
      assert List.last(sets).burpee_count == 2
      assert total_burpees(plan) == 102
    end

    test "duration within ±5s of target" do
      {plan, _} = run(%{pacing_style: :unbroken, burpee_count_target: 102}, 10)
      assert abs(total_duration(plan) - 1200) <= 5
    end
  end

  # ---------------------------------------------------------------------------
  # :unbroken × 1 reservation
  # ---------------------------------------------------------------------------

  describe ":unbroken, 1 reservation" do
    test "reservation rest is added on top of base inter-set rest" do
      {plan, _} =
        run(
          %{
            pacing_style: :unbroken,
            additional_rests: [%{rest_sec: 30, target_min: 10}]
          },
          10
        )

      [%Block{sets: sets}] = plan.blocks
      # 100 reps / 10 per set = 10 sets, 9 boundaries.
      # rest_per_gap = (1200 − 500 − 30) / 9 = 670/9 ≈ 74.44 → round 74.
      # Reservation lands on slot 50 → set 5; that set carries 74 + 30 = 104.
      assert Enum.at(sets, 4).end_of_set_rest == 104
      # Other non-last sets carry just 74.
      others =
        sets
        |> Enum.with_index()
        |> Enum.reject(fn {_s, i} -> i == 4 or i == 9 end)
        |> Enum.map(fn {s, _} -> s.end_of_set_rest end)

      assert Enum.all?(others, &(&1 == 74))
      assert List.last(sets).end_of_set_rest == 0
    end

    test "duration within ±5s of target" do
      {plan, _} =
        run(
          %{
            pacing_style: :unbroken,
            additional_rests: [%{rest_sec: 30, target_min: 10}]
          },
          10
        )

      assert abs(total_duration(plan) - 1200) <= 5
    end

    test "total burpees unchanged" do
      {plan, _} =
        run(
          %{
            pacing_style: :unbroken,
            additional_rests: [%{rest_sec: 30, target_min: 10}]
          },
          10
        )

      assert total_burpees(plan) == 100
    end
  end

  # ---------------------------------------------------------------------------
  # Plan wrapper round-trip
  # ---------------------------------------------------------------------------

  describe "plan wrapper" do
    test "additional_rests serialised as JSON text" do
      {plan, _} = run(%{additional_rests: [%{rest_sec: 30, target_min: 10}]})
      assert plan.additional_rests == "[{\"rest_sec\":30,\"target_min\":10}]"
    end

    test "carries scalar input fields verbatim" do
      {plan, inp} = run(%{})
      assert plan.name == inp.name
      assert plan.burpee_type == inp.burpee_type
      assert plan.target_duration_min == inp.target_duration_min
      assert plan.burpee_count_target == inp.burpee_count_target
      assert plan.sec_per_burpee == inp.sec_per_burpee
      assert plan.pacing_style == inp.pacing_style
    end
  end
end
