defmodule BurpeeTrainer.PlanSolver.InputTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{ExplicitRest, Infeasible, Input}

  test "accepts canonical fields without legacy normalization" do
    raw = %Input{
      name: "140 six-count",
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      level: :level_3,
      max_unbroken_reps: 8,
      explicit_rests: [
        %ExplicitRest{target_elapsed_sec: 720, duration_sec: 60, tolerance_sec: 60}
      ],
      sec_per_rep_override: 5.5
    }

    assert {:ok, input} = Input.normalize_and_validate(raw)
    assert input.target_duration_sec == 1_200
    assert input.max_unbroken_reps == 8
    assert input.sec_per_rep_override == 5.5

    assert input.explicit_rests == [
             %ExplicitRest{target_elapsed_sec: 720, duration_sec: 60, tolerance_sec: 60}
           ]
  end

  test "requires max unbroken reps for unbroken style after normalization" do
    raw = %Input{
      name: "missing max",
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      level: :level_3
    }

    assert {:error, %Infeasible{reason: :invalid_input, details: %{field: :max_unbroken_reps}}} =
             Input.normalize_and_validate(raw)
  end

  test "ignores max unbroken reps for even style" do
    raw = %Input{
      name: "even",
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :even,
      level: :level_3,
      max_unbroken_reps: 8
    }

    assert {:ok, input} = Input.normalize_and_validate(raw)
    assert input.max_unbroken_reps == nil
  end
end
