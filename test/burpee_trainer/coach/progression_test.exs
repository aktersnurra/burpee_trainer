defmodule BurpeeTrainer.Coach.ProgressionTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Coach.Progression
  alias BurpeeTrainer.Workouts.WorkoutSession
  @now ~U[2026-10-24 12:00:00Z]

  test "two successful comparable prescriptions support a small increase, not a large jump" do
    decision = Progression.decide([session(2, 1), session(1, 4)], :six_count, @now)
    assert decision.action == :progress
    assert decision.baseline_reps_per_20 == 100
    assert decision.evidence_ids == [2, 1]
    assert Progression.allows?(decision, 105, 1200)
    refute Progression.allows?(decision, 110, 1200)
    refute Progression.allows?(decision, 40, 1200)
  end

  test "a new higher target repeats until it has comparable successful evidence" do
    latest = %{session(2, 1) | burpee_count_actual: 105, burpee_count_planned: 105}
    decision = Progression.decide([latest, session(1, 4)], :six_count, @now)
    assert decision.action == :repeat
    refute Progression.allows?(decision, 110, 1200)
  end

  test "missing feedback, a difficult session and low energy do not justify escalation" do
    for attrs <- [%{mood: nil}, %{mood: -1}, %{context_low_energy: true}] do
      latest = struct!(session(2, 1), attrs)
      decision = Progression.decide([latest, session(1, 4)], :six_count, @now)
      assert decision.action == :repeat
      assert Progression.allows?(decision, 100, 1200)
      refute Progression.allows?(decision, 101, 1200)
    end
  end

  test "late fatigue repeats the prescription; early fatigue eases it" do
    late = %{session(1, 1) | kept_up: false, slip_at_sec: 900.0}
    early = %{late | slip_at_sec: 300.0}
    assert Progression.decide([late], :six_count, @now).action == :repeat
    decision = Progression.decide([early], :six_count, @now)
    assert decision.action == :ease
    assert Progression.allows?(decision, 90, 1200)
    refute Progression.allows?(decision, 100, 1200)
  end

  test "an early finish below target does not inflate performance by shortening the denominator" do
    failed = %{session(1, 1) | burpee_count_actual: 80, duration_sec_actual: 600}
    decision = Progression.decide([failed], :six_count, @now)
    assert decision.action == :ease
    assert decision.baseline_reps_per_20 == 80
    assert decision.max_reps_per_20 == 72
  end

  test "forty minutes holds one and a half times a twenty-minute session's reps, not twice" do
    # 150 in forty minutes is as good as 100 in twenty, so it counts as a repeat of it.
    long = %{
      session(2, 1)
      | burpee_count_actual: 150,
        burpee_count_planned: 150,
        duration_sec_actual: 2400,
        duration_sec_planned: 2400
    }

    decision = Progression.decide([long, session(1, 4)], :six_count, @now)
    assert decision.action == :progress
    assert decision.baseline_reps_per_20 == 100

    # 101 to 105 per twenty minutes is 152 to 157 in forty.
    assert Progression.slot_reps(decision, 2400) == %{min: 152, max: 157}
    assert Progression.allows?(decision, 157, 2400)
    refute Progression.allows?(decision, 158, 2400)
    refute Progression.allows?(decision, 151, 2400)
    assert Progression.slot_reps(%Progression{}, 2400) == nil
  end

  test "warmups, other types, future, stale and short unprescribed sessions are not progression evidence" do
    rows = [
      %{session(1, 1) | tags: "warmup"},
      %{session(2, 1) | burpee_type: :navy_seal},
      session(3, -1),
      session(4, 60),
      %{session(5, 1) | duration_sec_actual: 120, duration_sec_planned: nil}
    ]

    assert Progression.decide(rows, :six_count, @now).action == :establish
    assert Progression.decide(rows, :six_count, @now).evidence_ids == []
  end

  test "a missed week alone repeats demonstrated capacity rather than reducing it" do
    decision = Progression.decide([%{session(1, 14) | mood: nil}], :six_count, @now)
    assert decision.action == :repeat
    assert Progression.allows?(decision, 100, 1200)
  end

  test "evidence uses chronological order across month boundaries" do
    decision = Progression.decide([session(2, 24), session(1, 23)], :six_count, @now)
    assert decision.evidence_ids == [1, 2]
  end

  # Ten sets of ten at 8 s per rep with 40 s between, seen by the camera; set k's last rep
  # lands `finish.(k)` seconds after its beep.
  defp camera(session, finish) do
    work = %{"kind" => "work", "reps" => 10, "sec_per_rep_us" => 8_000_000}
    rest = %{"kind" => "rest", "duration_ms" => 40_000}

    cadence =
      for k <- 0..9, rep <- 1..10, do: round((k * 120 + rep * finish.(k) / 10) * 1_000)

    %{
      session
      | source_kind: :plan,
        display_name_snapshot: "Tens",
        capture_mode: :tracked,
        kept_up: true,
        program_snapshot: %{"events" => Enum.intersperse(List.duplicate(work, 10), rest)},
        cadence_ms: Jason.encode!(cadence)
    }
  end

  test "a window running out holds the reps even when they kept up" do
    tiring = camera(session(2, 1), fn k -> 80 + 4 * k end)

    decision =
      Progression.decide([tiring, camera(session(1, 4), fn _ -> 80 end)], :six_count, @now)

    assert decision.action == :repeat
    assert decision.reason == :slack_running_out
    refute Progression.allows?(decision, 101, 1200)
  end

  test "steady headroom in every window allows a bigger step than plain success" do
    easy = fn k -> camera(session(k, k * 3 - 2), fn _ -> 50 end) end
    decision = Progression.decide([easy.(1), easy.(2)], :six_count, @now)
    assert decision.reason == :repeated_success_with_headroom
    assert Progression.allows?(decision, 108, 1200)
    refute Progression.allows?(decision, 109, 1200)
  end

  defp session(id, days_ago) do
    %WorkoutSession{
      id: id,
      source_kind: :manual,
      state: :completed,
      burpee_type: :six_count,
      burpee_count_actual: 100,
      duration_sec_actual: 1200,
      burpee_count_planned: 100,
      duration_sec_planned: 1200,
      mood: 0,
      completed_at: DateTime.add(@now, -days_ago, :day)
    }
  end
end
