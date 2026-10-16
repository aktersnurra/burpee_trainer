defmodule BurpeeTrainer.Insights.FallbackTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias BurpeeTrainer.Insights.{Metrics, Narrator, Validator}

  test "no missing metric is invented" do
    assert Narrator.fallback(%{}) == %{"headline" => "Session saved", "points" => []}
    metrics = %{"week.minutes" => %{value: 15, unit: :minutes, label: "minutes"}}
    assert {:ok, _} = Validator.validate(Narrator.fallback(metrics), metrics)
  end

  property "fallback always validates its exact computed values" do
    check all(seconds <- integer(0..10000), reps <- integer(0..1000)) do
      session = %{
        id: 1,
        state: :completed,
        source_kind: :manual,
        completed_at: ~U[2026-10-06 12:00:00Z],
        burpee_type: :six_count,
        burpee_count_actual: reps,
        duration_sec_actual: seconds
      }

      metrics = Metrics.compute([session], [], ~D[2026-10-07], "Etc/UTC", ~D[2024-01-01])
      assert {:ok, _} = Validator.validate(Narrator.fallback(metrics), metrics)
    end
  end
end
