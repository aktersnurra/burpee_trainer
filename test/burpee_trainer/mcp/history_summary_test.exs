defmodule BurpeeTrainer.Mcp.HistorySummaryTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.AuthoritativeSession
  alias BurpeeTrainer.History
  alias BurpeeTrainer.Mcp.HistorySummary
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "empty selections have zero coverage and no measured pace" do
    assert {:ok, summary} = HistorySummary.summarize([], "Etc/UTC")
    assert summary["sessions"] == 0
    assert summary["actual_reps"] == 0
    assert summary["elapsed_seconds"] == 0
    assert summary["credited_seconds"] == 0
    assert summary["recorded_days"] == 0
    assert summary["training_days"] == 0
    assert summary["measurement_samples"] == 0
    assert summary["average_pace_sec"] == nil
    assert summary["measured_average_pace_sec"] == nil
    assert summary["best_normalized_reps_per_20_min"] == nil
    assert summary["by_type"] == []
    assert {:error, :invalid_timezone} = HistorySummary.summarize([], "Invalid/Zone")
  end

  test "actual totals count zero measurements but never substitute planned or invalid values" do
    sessions = [
      session(1, 10, 61),
      session(2, nil, 0),
      session(3, 0, nil),
      session(4, -1, -2),
      session(5, "12", 2.5),
      session(6, 7, nil)
    ]

    assert {:ok, summary} = HistorySummary.summarize(sessions, "Etc/UTC")
    assert summary["sessions"] == 6
    assert summary["actual_reps"] == 17
    assert summary["elapsed_seconds"] == 61
    assert summary["credited_seconds"] == 61
    assert summary["minutes"] == 1
    assert summary["actual_reps_samples"] == 3
    assert summary["elapsed_seconds_samples"] == 2
    assert summary["missing_actual_reps"] == 3
    assert summary["missing_elapsed_seconds"] == 4
    assert summary["measurement_samples"] == 1
    assert summary["unmeasured_sessions"] == 5
    assert summary["reps"] == 10
  end

  test "legacy single-type metrics match History while measured metrics include selected warmups" do
    sessions = [session(1, 10, 61), session(2, 30, 121), session(3, 20, 40, tags: "warmup")]
    measured = History.points(Enum.take(sessions, 2))
    assert {:ok, summary} = HistorySummary.summarize(sessions, "Etc/UTC")
    assert summary["actual_reps"] == 60
    assert summary["elapsed_seconds"] == 222
    assert summary["credited_seconds"] == 182
    assert summary["minutes"] == 3
    assert summary["reps"] == Enum.sum(Enum.map(measured, & &1.actual_reps))
    assert summary["best_reps_per_20_min"] == Enum.max(Enum.map(measured, & &1.density))
    assert summary["average_pace_sec"] == 4.55
    assert summary["measured_average_pace_sec"] == 3.7
    assert summary["measurement_samples"] == 3
    assert summary["legacy_measurement_samples"] == 2
    assert summary["warmup_sessions"] == 1
    assert summary["best_normalized_reps_per_20_min"] == 600
    refute Enum.any?(sessions, &AuthoritativeSession.prescribed_plan_pb_eligible?/1)
    assert [typed] = summary["by_type"]
    assert typed == summary |> Map.delete("by_type") |> Map.put("burpee_type", "six_count")
  end

  test "mixed-type overall pace is null and per-type weighted pace is retained" do
    sessions = [
      session(1, 10, 60),
      session(2, 30, 120),
      session(3, 5, 100, burpee_type: :navy_seal)
    ]

    assert {:ok, summary} = HistorySummary.summarize(sessions, "Etc/UTC")
    assert summary["average_pace_sec"] == nil
    assert summary["measured_average_pace_sec"] == nil
    assert summary["pace_comparability"] == "mixed_burpee_types"
    assert [navy, six] = summary["by_type"]
    assert navy["burpee_type"] == "navy_seal"
    assert navy["average_pace_sec"] == 20.0
    assert six["average_pace_sec"] == 4.5
    assert {:ok, ^summary} = HistorySummary.summarize(Enum.reverse(sessions), "Etc/UTC")
  end

  test "recorded and credited training days use local dates across DST and canonical warmups" do
    sessions = [
      session(1, 10, 60, completed_at: ~U[2026-03-29 00:30:00Z]),
      session(2, 10, 60, completed_at: ~U[2026-03-29 01:30:00Z]),
      session(3, 10, 60, completed_at: ~U[2026-03-29 22:30:00Z], tags: "warmup"),
      session(4, 0, 0, completed_at: ~U[2026-03-30 22:30:00Z]),
      session(5, 10, 60, completed_at: ~U[2026-03-31 22:30:00Z], tags: "warmup,other")
    ]

    assert {:ok, summary} = HistorySummary.summarize(sessions, "Europe/Stockholm")
    assert summary["recorded_days"] == 4
    assert summary["training_days"] == 2
    assert summary["warmup_sessions"] == 1
    assert summary["credited_seconds"] == 180
    assert {:error, :invalid_timezone} = HistorySummary.summarize(sessions, "Invalid/Zone")
  end

  defp session(id, reps, seconds, attrs \\ []) do
    struct!(
      WorkoutSession,
      Keyword.merge(
        [
          id: id,
          state: :completed,
          source_kind: :manual,
          completed_at: ~U[2026-03-29 00:30:00Z],
          burpee_type: :six_count,
          burpee_count_actual: reps,
          duration_sec_actual: seconds,
          burpee_count_planned: 999,
          duration_sec_planned: 1200
        ],
        attrs
      )
    )
  end
end
