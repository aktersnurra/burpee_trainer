defmodule BurpeeTrainer.PlanWizard.LpTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{Lp, PlanInput, SlotModel}

  describe "build/1 — degenerate cases" do
    test "1-rep workout produces an empty feasible problem" do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 1,
        burpee_count_target: 1,
        sec_per_burpee: 4.0,
        pacing_style: :even
      }

      model = SlotModel.new(input, nil)
      problem = Lp.build(model)

      assert problem.variables == []
      assert problem.constraints == []
      assert problem.objective_terms == []
    end
  end

  describe "build/1 — no reservations" do
    test ":even style produces r_i vars, e_i vars, total-duration equality, deviation rows" do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 5,
        sec_per_burpee: 4.0,
        pacing_style: :even
      }

      model = SlotModel.new(input, nil)
      problem = Lp.build(model)

      r_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "r_"))
      e_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "e_"))
      assert length(r_vars) == 4
      assert length(e_vars) == 4
      Enum.each(r_vars, fn v -> assert v.type == :continuous and v.lower == 0.0 end)

      total_row = Enum.find(problem.constraints, &(&1.name == "TOTAL_DUR"))
      assert total_row.comparator == :eq
      assert_in_delta total_row.rhs, 600.0 - 5 * 4.0, 1.0e-6

      assert MapSet.new(Enum.map(total_row.terms, &elem(&1, 0))) ==
               MapSet.new(["r_1", "r_2", "r_3", "r_4"])

      dev_rows = Enum.filter(problem.constraints, &String.starts_with?(&1.name, "DEV_"))
      assert length(dev_rows) == 8

      assert problem.objective_sense == :minimize
      obj_vars = MapSet.new(Enum.map(problem.objective_terms, &elem(&1, 0)))
      assert obj_vars == MapSet.new(["e_1", "e_2", "e_3", "e_4"])
    end

    test ":unbroken style produces zero-rest equality rows for intra-set slots" do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 10,
        sec_per_burpee: 4.0,
        pacing_style: :unbroken,
        reps_per_set: 5
      }

      model = SlotModel.new(input, 5)
      problem = Lp.build(model)

      zero_rows = Enum.filter(problem.constraints, &String.starts_with?(&1.name, "ZERO_SLOT_"))
      assert length(zero_rows) == 8

      Enum.each(zero_rows, fn row ->
        assert row.comparator == :eq
        assert row.rhs == 0.0
        assert length(row.terms) == 1
      end)
    end
  end

  describe "build/1 — with reservations" do
    test ":even style: one reservation produces x, y, d vars and linkage rows" do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 10,
        sec_per_burpee: 12.0,
        pacing_style: :even,
        additional_rests: [%{rest_sec: 60, target_min: 5}]
      }

      model = SlotModel.new(input, nil)
      problem = Lp.build(model)

      x_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "x_"))
      y_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "y_"))
      d_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "d_"))

      assert length(d_vars) == 1
      assert length(x_vars) == length(y_vars)
      assert length(x_vars) >= 1

      Enum.each(x_vars, fn v -> assert v.type == :binary end)

      assert Enum.any?(problem.constraints, fn c ->
               c.name == "ASSIGN_1" and c.comparator == :eq and c.rhs == 1.0
             end)

      assert Enum.any?(problem.constraints, fn c ->
               c.name == "TOL_1" and c.comparator == :leq and c.rhs == 30.0
             end)

      assert Enum.any?(problem.constraints, &(&1.name == "PERR_POS_1"))
      assert Enum.any?(problem.constraints, &(&1.name == "PERR_NEG_1"))

      assert Enum.any?(problem.objective_terms, fn {n, c} -> n == "d_1" and c == 1.0 end)
    end

    test ":even style: ordering constraint for two reservations" do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 20,
        burpee_count_target: 20,
        sec_per_burpee: 12.0,
        pacing_style: :even,
        additional_rests: [
          %{rest_sec: 60, target_min: 7},
          %{rest_sec: 60, target_min: 14}
        ]
      }

      model = SlotModel.new(input, nil)
      problem = Lp.build(model)

      assert Enum.any?(problem.constraints, fn c ->
               c.name == "ORDER_1" and c.comparator == :geq and c.rhs == 1.0
             end)
    end

    test ":unbroken style: AllowedSlots restricted to set boundaries" do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 20,
        burpee_count_target: 20,
        sec_per_burpee: 12.0,
        pacing_style: :unbroken,
        reps_per_set: 5,
        additional_rests: [%{rest_sec: 60, target_min: 10}]
      }

      model = SlotModel.new(input, 5)
      problem = Lp.build(model)

      x_indices =
        problem.variables
        |> Enum.filter(&String.starts_with?(&1.name, "x_1_"))
        |> Enum.map(fn %{name: name} ->
          ["x", "1", i] = String.split(name, "_")
          String.to_integer(i)
        end)
        |> Enum.sort()

      assert Enum.all?(x_indices, fn i -> rem(i, 5) == 0 end)
      assert Enum.member?(x_indices, 10)
    end
  end
end
