defmodule BurpeeTrainer.PlanSolver.LpTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{Input, Lp}

  defp base_input(overrides \\ %{}) do
    Map.merge(
      %{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 5,
        pacing_style: :even,
        level: :level_1c,
        additional_rests: []
      },
      overrides
    )
    |> then(fn m -> struct!(Input, m) end)
  end

  describe "build/2 — no reservations, :even" do
    test "includes p variable with correct bounds" do
      problem = Lp.build(base_input(), nil)

      p_var = Enum.find(problem.variables, &(&1.name == "p"))
      assert p_var != nil
      assert p_var.type == :continuous
      # level_1c ceiling is 6.0
      assert_in_delta p_var.lower, 6.0, 1.0e-9
      assert p_var.upper == :pos_inf or p_var.upper >= 6.0
    end

    test "TOTAL_DUR row has both p and r_i terms" do
      problem = Lp.build(base_input(), nil)
      row = Enum.find(problem.constraints, &(&1.name == "TOTAL_DUR"))

      assert row != nil
      assert row.comparator == :eq

      term_names = Enum.map(row.terms, &elem(&1, 0)) |> MapSet.new()
      assert MapSet.member?(term_names, "p")
      assert MapSet.member?(term_names, "r_1")

      # p coefficient should be N (= 5)
      {_, p_coef} = Enum.find(row.terms, fn {n, _} -> n == "p" end)
      assert_in_delta p_coef, 5.0, 1.0e-9

      # RHS = target_sec - additional_rest_total = 600
      assert_in_delta row.rhs, 600.0, 1.0e-9
    end

    test "DEV rows reference p" do
      problem = Lp.build(base_input(), nil)

      dev_rows = Enum.filter(problem.constraints, &String.starts_with?(&1.name, "DEV_"))
      assert length(dev_rows) == 8

      Enum.each(dev_rows, fn row ->
        term_names = Enum.map(row.terms, &elem(&1, 0)) |> MapSet.new()

        assert MapSet.member?(term_names, "p"),
               "expected DEV row #{row.name} to reference p"
      end)
    end

    test "objective minimizes -α*p and ε*e_i terms" do
      problem = Lp.build(base_input(), nil)
      assert problem.objective_sense == :minimize

      {_, p_coef} = Enum.find(problem.objective_terms, fn {n, _} -> n == "p" end)
      # α = 0.6, coefficient should be -0.6
      assert_in_delta p_coef, -0.6, 1.0e-9

      e_terms =
        Enum.filter(problem.objective_terms, fn {n, _} -> String.starts_with?(n, "e_") end)

      assert length(e_terms) == 4
      Enum.each(e_terms, fn {_, c} -> assert_in_delta c, 1.0e-3, 1.0e-9 end)
    end
  end

  describe "build/2 — :unbroken" do
    test "zero-weight slots still get ZERO_SLOT constraints" do
      input = base_input(%{pacing_style: :unbroken, burpee_count_target: 10})
      problem = Lp.build(input, 5)

      zero_rows = Enum.filter(problem.constraints, &String.starts_with?(&1.name, "ZERO_SLOT_"))
      assert length(zero_rows) == 8
    end
  end

  describe "build/2 — with reservation" do
    test "reservation produces x, y, d vars; TOTAL_DUR still has p" do
      input =
        base_input(%{
          burpee_count_target: 10,
          additional_rests: [%{rest_sec: 60, target_min: 5}]
        })

      problem = Lp.build(input, nil)

      row = Enum.find(problem.constraints, &(&1.name == "TOTAL_DUR"))
      term_names = Enum.map(row.terms, &elem(&1, 0)) |> MapSet.new()
      assert MapSet.member?(term_names, "p")

      # RHS = 600 - 60 = 540
      assert_in_delta row.rhs, 540.0, 1.0e-9

      d_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "d_"))
      assert length(d_vars) == 1
    end

    test "y_linearization rows include p coefficient" do
      input =
        base_input(%{
          burpee_count_target: 10,
          additional_rests: [%{rest_sec: 60, target_min: 5}]
        })

      problem = Lp.build(input, nil)

      ybnd_se_rows =
        Enum.filter(problem.constraints, &String.starts_with?(&1.name, "YBND_SE_"))

      Enum.each(ybnd_se_rows, fn row ->
        term_names = Enum.map(row.terms, &elem(&1, 0)) |> MapSet.new()

        assert MapSet.member?(term_names, "p"),
               "expected #{row.name} to reference p"
      end)
    end
  end
end
