defmodule BurpeeTrainer.Insights.MetricsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias BurpeeTrainer.Insights.Metrics

  defp session(id, at, reps, seconds, type \\ :six_count) do
    %{
      id: id,
      user_id: 1,
      state: :completed,
      source_kind: :manual,
      completed_at: at,
      burpee_type: type,
      burpee_count_actual: reps,
      duration_sec_actual: seconds,
      tags: nil
    }
  end

  test "actual completed facts only, future excluded and latest uses timestamp then id" do
    rows = [
      session(1, ~U[2026-10-05 12:00:00Z], 120, 1200),
      session(2, ~U[2026-10-07 12:00:00Z], 60, 1200, :navy_seal),
      session(3, ~U[2026-10-08 12:00:00Z], 999, 9999),
      %{session(4, ~U[2026-10-07 12:00:00Z], 999, 9999) | state: :started}
    ]

    m = Metrics.compute(rows, [], ~D[2026-10-07], "Etc/UTC", ~D[2024-01-01])
    assert m["week.minutes"].value == 40
    assert m["week.reps.six_count"].value == 120
    assert m["session.reps"].value == 60
    assert Metrics.format(m["session.pace_sec"]) == "20.0"
  end

  test "local midnight, missing actuals and zero reps" do
    rows = [
      session(1, ~U[2026-10-05 00:30:00Z], 0, 60),
      session(3, ~U[2026-10-06 12:00:00Z], nil, nil)
    ]

    m = Metrics.compute(rows, [], ~D[2026-10-07], "America/New_York", ~D[2024-01-01])
    assert m["week.minutes"].value == 0
    assert m["session.reps"].value == 0
    refute Map.has_key?(m, "session.pace_sec")
  end

  test "empty input has no session or comparative metrics" do
    m = Metrics.compute([], [], ~D[2026-10-07], "Etc/UTC", ~D[2024-01-01])
    assert m["week.minutes"].value == 0
    refute Map.has_key?(m, "session.reps")
    refute Map.has_key?(m, "pace.change_6w.six_count")
  end

  test "scope excludes foreign facts and goals, and timestamps after now" do
    scope = %BurpeeTrainer.Accounts.Scope{
      user: %BurpeeTrainer.Accounts.User{
        id: 1,
        timezone: "Etc/UTC",
        inserted_at: ~U[2024-01-01 00:00:00Z]
      }
    }

    rows = [
      session(1, ~U[2026-10-07 10:00:00Z], 10, 120),
      %{session(2, ~U[2026-10-07 11:00:00Z], 999, 1200) | user_id: 2},
      session(3, ~U[2026-10-07 13:00:00Z], 999, 1200)
    ]

    goals = [
      %{
        id: 1,
        user_id: 2,
        status: :active,
        burpee_type: :six_count,
        burpee_count_target: 100,
        duration_sec_target: 1200
      }
    ]

    m = Metrics.for_scope(scope, rows, goals, ~U[2026-10-07 12:00:00Z])
    assert m["week.minutes"].value == 2
    assert m["session.reps"].value == 10
    refute Map.has_key?(m, "goal.1.progress_pct")
  end

  test "completed-week streak, comparison window, active goal clamp and categorical levels" do
    rows = [
      session(1, ~U[2026-09-22 12:00:00Z], 100, 4800),
      session(2, ~U[2026-09-29 12:00:00Z], 100, 4800),
      session(3, ~U[2026-10-06 12:00:00Z], 100, 1000)
    ]

    goals = [
      %{
        id: 7,
        status: :active,
        burpee_type: :six_count,
        burpee_count_target: 80,
        duration_sec_target: 1200
      },
      %{
        id: 8,
        status: :abandoned,
        burpee_type: :six_count,
        burpee_count_target: 80,
        duration_sec_target: 1200
      }
    ]

    m = Metrics.compute(rows, goals, ~D[2026-10-07], "Etc/UTC", ~D[2024-01-01])
    assert m["streak.weeks"].value == 2
    assert m["pace.change_6w.six_count"].value == -38.0
    assert m["goal.7.progress_pct"].value == 100
    refute Map.has_key?(m, "goal.8.progress_pct")

    assert m["level.six_count"] == %{
             value: "level_1c",
             unit: :level,
             label: "current six_count level"
           }
  end

  test "warmup latest facts are real but do not earn aggregate credit" do
    ordinary = session(1, ~U[2026-10-05 12:00:00Z], 10, 120)
    warmup = %{session(2, ~U[2026-10-06 12:00:00Z], 7, 60) | tags: "warmup"}
    m = Metrics.compute([ordinary, warmup], [], ~D[2026-10-07], "Etc/UTC", ~D[2024-01-01])
    assert m["session.reps"].value == 7
    assert m["session.duration_min"].value == 1
    assert m["week.minutes"].value == 2
    assert m["week.reps.six_count"].value == 10
  end

  test "target projection never substitutes a later, foreign or invalid completed session" do
    scope = %BurpeeTrainer.Accounts.Scope{
      user: %BurpeeTrainer.Accounts.User{
        id: 1,
        timezone: "Etc/UTC",
        inserted_at: ~U[2024-01-01 00:00:00Z]
      }
    }

    target = session(1, ~U[2026-10-06 12:00:00Z], 7, 60)
    newer = session(2, ~U[2026-10-06 12:00:00Z], 999, 1200)
    assert {:ok, m} = Metrics.for_session(scope, [target, newer], [], target)
    assert m["session.reps"].value == 7
    assert m["session.duration_min"].value == 1

    for invalid <- [
          %{target | user_id: 2},
          %{target | state: :started},
          %{target | source_kind: :plan}
        ] do
      assert {:error, :invalid_target} = Metrics.for_session(scope, [newer], [], invalid)
    end

    missing = %{target | burpee_count_actual: nil}
    assert {:ok, m} = Metrics.for_session(scope, [missing, newer], [], missing)
    refute Map.has_key?(m, "session.reps")
    refute Map.has_key?(m, "session.pace_sec")
  end

  property "weekly minutes sum seconds before rounding and input order is irrelevant" do
    check all(durations <- list_of(integer(0..3600), max_length: 20)) do
      rows =
        durations
        |> Enum.with_index()
        |> Enum.map(fn {d, i} ->
          session(i, ~U[2026-10-06 12:00:00Z], 10, d)
        end)

      m = Metrics.compute(rows, [], ~D[2026-10-07], "Etc/UTC", ~D[2024-01-01])
      assert m["week.minutes"].value == div(Enum.sum(durations), 60)

      assert m ==
               Metrics.compute(Enum.reverse(rows), [], ~D[2026-10-07], "Etc/UTC", ~D[2024-01-01])
    end
  end

  test "the sign-up week reports its pro-rated target" do
    # Signed up Saturday 2026-10-10: 40 minutes that week, 80 the next.
    m = Metrics.compute([], [], ~D[2026-10-10], "Etc/UTC", ~D[2026-10-10])
    assert m["week.target_minutes"].value == 40

    m = Metrics.compute([], [], ~D[2026-10-12], "Etc/UTC", ~D[2026-10-10])
    assert m["week.target_minutes"].value == 80
  end

  test "a sign-up week met at its pro-rated target counts toward the streak" do
    rows = [
      session(1, ~U[2026-09-26 12:00:00Z], 50, 2_400),
      session(2, ~U[2026-09-29 12:00:00Z], 100, 4_800)
    ]

    m = Metrics.compute(rows, [], ~D[2026-10-07], "Etc/UTC", ~D[2026-09-26])
    assert m["streak.weeks"].value == 2
  end
end
