defmodule BurpeeTrainer.Analytics.OutputTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Analytics.Output

  test "strict narrative rejects forged evidence, missing citations and oversize strings" do
    valid = %{
      "status" => "answered",
      "interpretation" => "volume",
      "answer" => "One",
      "findings" => [%{"text" => "One", "evidence_ids" => ["q1"]}],
      "limitations" => []
    }

    assert {:ok, ^valid} = Output.narrative(valid, ["q1"])
    assert {:error, :invalid_analytics_output} = Output.narrative(valid, [])

    assert {:error, :invalid_analytics_output} =
             Output.narrative(Map.put(valid, "evidence", []), ["q1"])

    assert {:error, :invalid_analytics_output} =
             Output.narrative(Map.put(valid, "findings", []), ["q1"])

    assert {:error, :invalid_analytics_output} =
             Output.narrative(Map.put(valid, "answer", String.duplicate("x", 2049)), ["q1"])
  end
end
