defmodule BurpeeTrainer.Evals.ScenariosTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Evals.Scenarios

  test "every scenario uses the actual Home form changeset/request path" do
    scenarios = Scenarios.load!("authoring", nil)
    assert length(scenarios) == 4

    for scenario <- scenarios do
      assert {:ok, %{request: request, instruction: instruction}} = Scenarios.prepare(scenario)
      assert request.target_reps == scenario["expected"]["target_reps"]
      assert request.target_duration_sec == scenario["expected"]["target_duration_sec"]
      assert request.burpee_type == scenario["expected"]["burpee_type"]
      assert request.recovery == scenario["expected"]["recovery"]
      assert is_binary(instruction)
    end

    # Pauses are said in the note, as on Home; the coach reads them when the eval runs.
    [scenario] = Scenarios.load!("authoring", "minute_blocks_two_pauses")
    assert {:ok, %{request: request, note: note}} = Scenarios.prepare(scenario)
    assert request.timed_rests == []
    assert note =~ "11:00" and note =~ "18:00"
  end

  test "invalid form and unknown scenario fail without authoring" do
    assert {:error, :invalid_form} = Scenarios.prepare(%{"form" => %{"reps" => 0}})
    assert_raise Mix.Error, fn -> Scenarios.load!("authoring", "missing") end
  end
end
