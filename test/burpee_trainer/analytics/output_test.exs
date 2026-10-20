defmodule BurpeeTrainer.Analytics.OutputTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Analytics.Output

  test "non-answer narratives cannot preserve fabricated claims in any field" do
    for status <- ~w(insufficient_data needs_clarification budget_exhausted) do
      fabricated = %{
        "status" => status,
        "interpretation" => "You completed 999999 reps.",
        "answer" => "You completed 999999 reps.",
        "findings" => [%{"text" => "You completed nine million reps.", "evidence_ids" => []}],
        "limitations" => ["Your pace improved by 50%."]
      }

      assert {:ok, safe} = Output.narrative(fabricated, [])
      assert safe["findings"] == []
      assert safe["interpretation"] == ""
      refute String.contains?(Jason.encode!(safe), "999999")
      refute String.contains?(Jason.encode!(safe), "50%")
      refute String.contains?(Jason.encode!(safe), "nine million")

      forged = Map.merge(fabricated, %{"evidence" => [], "trace_id" => Ecto.UUID.generate()})
      assert {:error, :invalid_analytics_output} = Output.validate(forged, [])
    end
  end

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
