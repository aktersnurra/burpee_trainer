defmodule BurpeeTrainer.ScoringTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Scoring

  defp session(attrs) do
    Map.merge(
      %{
        burpee_type: :six_count,
        burpee_count_actual: 50,
        duration_sec_actual: 600,
        inserted_at: ~U[2026-01-05 12:00:00Z],
        tags: nil
      },
      attrs
    )
  end

  describe "pushups/2" do
    test "six_count is worth one push-up per burpee" do
      assert Scoring.pushups(:six_count, 40) == 40
    end

    test "navy_seal is worth three push-ups per burpee" do
      assert Scoring.pushups(:navy_seal, 40) == 120
    end

    test "zero burpees is zero push-ups" do
      assert Scoring.pushups(:six_count, 0) == 0
      assert Scoring.pushups(:navy_seal, 0) == 0
    end

    test "navy seal always outweighs six count for equal reps" do
      for n <- [1, 7, 50, 325] do
        assert Scoring.pushups(:navy_seal, n) > Scoring.pushups(:six_count, n)
      end
    end
  end

  describe "session_pushups/1" do
    test "warmup sessions score zero" do
      assert Scoring.session_pushups(session(%{tags: "warmup", burpee_count_actual: 99})) == 0
    end

    test "malformed sessions score zero" do
      assert Scoring.session_pushups(%{}) == 0
    end

    test "weights by type" do
      assert Scoring.session_pushups(session(%{burpee_type: :navy_seal, burpee_count_actual: 10})) ==
               30
    end
  end

  describe "total_pushups/1" do
    test "sums across sessions, excluding warmup" do
      sessions = [
        session(%{burpee_type: :six_count, burpee_count_actual: 100}),
        session(%{burpee_type: :navy_seal, burpee_count_actual: 20}),
        session(%{tags: "warmup", burpee_count_actual: 999})
      ]

      assert Scoring.total_pushups(sessions) == 100 + 60
    end

    test "empty list is zero" do
      assert Scoring.total_pushups([]) == 0
    end
  end

  describe "weekly_pushups/1" do
    test "groups by ISO week and sums, descending by week_start" do
      sessions = [
        session(%{inserted_at: ~U[2026-01-05 12:00:00Z], burpee_count_actual: 50}),
        session(%{inserted_at: ~U[2026-01-06 12:00:00Z], burpee_count_actual: 30}),
        session(%{inserted_at: ~U[2026-01-13 12:00:00Z], burpee_count_actual: 10})
      ]

      result = Scoring.weekly_pushups(sessions)

      assert [%{week_start: w1, pushups: 10}, %{week_start: w0, pushups: 80}] = result
      assert Date.compare(w1, w0) == :gt
    end

    test "weekly sum equals total across all weeks" do
      sessions = [
        session(%{inserted_at: ~U[2026-01-05 12:00:00Z], burpee_count_actual: 50}),
        session(%{inserted_at: ~U[2026-01-13 12:00:00Z], burpee_count_actual: 30}),
        session(%{inserted_at: ~U[2026-01-20 12:00:00Z], burpee_count_actual: 10})
      ]

      weekly_total = sessions |> Scoring.weekly_pushups() |> Enum.map(& &1.pushups) |> Enum.sum()
      assert weekly_total == Scoring.total_pushups(sessions)
    end
  end

  describe "week_pushups/2" do
    test "only counts the ISO week containing the date" do
      sessions = [
        session(%{inserted_at: ~U[2026-01-05 12:00:00Z], burpee_count_actual: 50}),
        session(%{inserted_at: ~U[2026-01-13 12:00:00Z], burpee_count_actual: 30})
      ]

      assert Scoring.week_pushups(sessions, ~D[2026-01-07]) == 50
      assert Scoring.week_pushups(sessions, ~D[2026-01-13]) == 30
    end
  end

  describe "balance/1 and balanced_week?/1" do
    defp week(six_minutes, navy_minutes) do
      six =
        for _ <- 1..six_minutes,
            do: session(%{burpee_type: :six_count, duration_sec_actual: 60})

      navy =
        for _ <- 1..navy_minutes,
            do: session(%{burpee_type: :navy_seal, duration_sec_actual: 60})

      six ++ navy
    end

    test "even 50/50 over the goal is balanced" do
      assert Scoring.balanced_week?(week(50, 50))
    end

    test "lopsided weeks are not balanced even over the goal" do
      refute Scoring.balanced_week?(week(90, 10))
    end

    test "balanced split but under the minute goal is not balanced" do
      refute Scoring.balanced_week?(week(20, 20))
    end

    test "ratio is symmetric in the two types" do
      assert Scoring.balance(week(40, 60)).ratio == Scoring.balance(week(60, 40)).ratio
    end

    test "exactly 40/40 split (of 100 min) is balanced" do
      # 40 min each + 20 min six on top → six 60, navy 40, total 100, each ≥ 40%
      assert Scoring.balanced_week?(week(60, 40))
    end

    test "warmup minutes are excluded from balance" do
      sessions =
        week(50, 50) ++
          [session(%{burpee_type: :navy_seal, duration_sec_actual: 6000, tags: "warmup"})]

      assert Scoring.balanced_week?(sessions)
    end
  end
end
