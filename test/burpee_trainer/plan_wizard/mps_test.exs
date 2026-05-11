defmodule BurpeeTrainer.PlanWizard.MpsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{Lp, Mps, PlanInput, SlotModel}

  test "serializes a minimal no-reservation :even problem to a valid MPS string" do
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
    text = Mps.serialize(problem)

    assert text =~ ~r/^NAME\s+BURPEE_PLAN/
    assert text =~ "ROWS"
    assert text =~ "COLUMNS"
    assert text =~ "RHS"
    assert text =~ "BOUNDS"
    assert text =~ ~r/ENDATA\s*\z/

    assert text =~ ~r/^\s*N\s+COST/m
    assert text =~ ~r/^\s*E\s+TOTAL_DUR/m
  end

  test "wraps binary variables in INTORG/INTEND markers" do
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
    text = Mps.serialize(problem)

    assert text =~ "'MARKER'"
    assert text =~ "'INTORG'"
    assert text =~ "'INTEND'"
  end

  test "round-trips through HiGHS without error" do
    if System.find_executable("highs") do
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
      text = Mps.serialize(problem)

      path =
        Path.join(
          System.tmp_dir!(),
          "mps_round_trip_#{:erlang.unique_integer([:positive])}.mps"
        )

      File.write!(path, text)

      try do
        {output, exit_code} = System.cmd("highs", [path], stderr_to_stdout: true)
        assert exit_code == 0, "highs failed: #{output}"
      after
        File.rm(path)
      end
    end
  end
end
