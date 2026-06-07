defmodule BurpeeTrainer.WeeklyTrainingContractTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.WeeklyTrainingContract
  alias BurpeeTrainer.Workouts.WorkoutSession

  describe "contract/0" do
    test "is fixed at 80 minutes across four 20 minute slots with 2+2 split" do
      contract = WeeklyTrainingContract.contract()

      assert contract.target_min == 80
      assert contract.standard_session_duration_min == 20
      assert length(contract.slots) == 4
      assert Enum.count(contract.slots, &(&1.burpee_type == :six_count)) == 2
      assert Enum.count(contract.slots, &(&1.burpee_type == :navy_seal)) == 2
      assert Enum.all?(contract.slots, &(&1.duration_min == 20))
    end
  end

  describe "status/2" do
    test "normal 20 minute sessions consume matching standard slots" do
      week_start = ~D[2026-06-01]

      sessions = [
        session(:six_count, 20, ~U[2026-06-02 10:00:00Z]),
        session(:navy_seal, 20, ~U[2026-06-03 10:00:00Z])
      ]

      status = WeeklyTrainingContract.status(sessions, week_start)

      assert status.completed_min == 40
      assert status.remaining_min == 40
      assert status.six_count.completed_standard_sessions == 1
      assert status.six_count.remaining_standard_sessions == 1
      assert status.navy_seal.completed_standard_sessions == 1
      assert status.navy_seal.remaining_standard_sessions == 1
      assert status.status == :in_progress
    end

    test "near-20-minute sessions count as standard sessions" do
      week_start = ~D[2026-06-01]

      sessions = [
        session_sec(:six_count, 1199, ~U[2026-06-02 10:00:00Z]),
        session_sec(:six_count, 1199, ~U[2026-06-03 10:00:00Z]),
        session_sec(:navy_seal, 1199, ~U[2026-06-04 10:00:00Z]),
        session_sec(:navy_seal, 1199, ~U[2026-06-05 10:00:00Z])
      ]

      status = WeeklyTrainingContract.status(sessions, week_start)

      assert status.completed_min == 80
      assert status.remaining_min == 0
      assert status.status == :complete
    end

    test "warmup sessions do not count toward weekly contract" do
      week_start = ~D[2026-06-01]

      sessions = [
        session(:six_count, 20, ~U[2026-06-02 10:00:00Z], tags: "warmup"),
        session(:navy_seal, 20, ~U[2026-06-03 10:00:00Z])
      ]

      status = WeeklyTrainingContract.status(sessions, week_start)

      assert status.completed_min == 20
      assert status.six_count.completed_standard_sessions == 0
      assert status.navy_seal.completed_standard_sessions == 1
    end

    test "manual 40 minute session counts toward minutes but marks non-standard" do
      week_start = ~D[2026-06-01]

      sessions = [
        session(:six_count, 20, ~U[2026-06-02 10:00:00Z]),
        session(:six_count, 20, ~U[2026-06-03 10:00:00Z]),
        session(:navy_seal, 40, ~U[2026-06-04 10:00:00Z])
      ]

      status = WeeklyTrainingContract.status(sessions, week_start)

      assert status.completed_min == 80
      assert status.remaining_min == 0
      assert status.navy_seal.completed_min == 40
      assert status.navy_seal.completed_standard_sessions == 0
      assert status.navy_seal.remaining_standard_sessions == 2
      assert status.status == :non_standard
    end
  end

  describe "catch_up_available?/1" do
    test "allows catch-up only on Saturday or Sunday" do
      refute WeeklyTrainingContract.catch_up_available?(~D[2026-06-05])
      assert WeeklyTrainingContract.catch_up_available?(~D[2026-06-06])
      assert WeeklyTrainingContract.catch_up_available?(~D[2026-06-07])
      refute WeeklyTrainingContract.catch_up_available?(~D[2026-06-08])
    end
  end

  describe "remaining_slots/2" do
    test "returns unconsumed canonical slots without scheduling days" do
      week_start = ~D[2026-06-01]
      sessions = [session(:six_count, 20, ~U[2026-06-02 10:00:00Z])]

      slots = WeeklyTrainingContract.remaining_slots(sessions, week_start)

      assert Enum.map(slots, & &1.burpee_type) == [:six_count, :navy_seal, :navy_seal]
      refute Enum.any?(slots, &Map.has_key?(&1, :day))
    end
  end

  defp session(type, duration_min, inserted_at, attrs \\ []) do
    session_sec(type, duration_min * 60, inserted_at, attrs)
  end

  defp session_sec(type, duration_sec, inserted_at, attrs \\ []) do
    struct!(
      WorkoutSession,
      Keyword.merge(
        [
          burpee_type: type,
          duration_sec_actual: duration_sec,
          burpee_count_actual: 1,
          inserted_at: inserted_at
        ],
        attrs
      )
    )
  end
end
