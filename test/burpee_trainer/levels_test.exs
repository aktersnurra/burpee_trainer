defmodule BurpeeTrainer.LevelsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Levels

  defp session(attrs) do
    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        burpee_type: :six_count,
        burpee_count_actual: 50,
        duration_sec_actual: 600,
        inserted_at: ~U[2026-01-01 12:00:00Z]
      },
      attrs
    )
  end

  describe "current_level/1" do
    test "returns :level_1a with zero sessions" do
      assert Levels.current_level([]) == :level_1a
    end

    test "returns the lower of the two per-type levels" do
      sessions = [
        session(%{burpee_type: :six_count, burpee_count_actual: 100}),
        session(%{burpee_type: :navy_seal, burpee_count_actual: 20})
      ]

      # six_count at 1c (100), navy_seal at 1b (20) — overall = 1b
      assert Levels.current_level(sessions) == :level_1b
    end

    test "returns :graduated when both types meet graduated threshold" do
      sessions = [
        session(%{burpee_type: :six_count, burpee_count_actual: 325}),
        session(%{burpee_type: :navy_seal, burpee_count_actual: 150})
      ]

      assert Levels.current_level(sessions) == :graduated
    end

    test "bottleneck type keeps overall level down" do
      sessions = [
        session(%{burpee_type: :six_count, burpee_count_actual: 325}),
        session(%{burpee_type: :navy_seal, burpee_count_actual: 1})
      ]

      assert Levels.current_level(sessions) == :level_1a
    end
  end

  describe "level_for_type/2" do
    test "returns :level_1a when no sessions" do
      assert Levels.level_for_type([], :six_count) == :level_1a
    end

    test "sessions over 1200s do not qualify" do
      sessions = [session(%{burpee_count_actual: 100, duration_sec_actual: 1201})]
      assert Levels.level_for_type(sessions, :six_count) == :level_1a
    end

    test "sessions with 0 burpees do not qualify" do
      sessions = [session(%{burpee_count_actual: 0, duration_sec_actual: 600})]
      assert Levels.level_for_type(sessions, :six_count) == :level_1a
    end

    test "picks the highest achieved landmark across multiple sessions" do
      sessions = [
        session(%{burpee_count_actual: 50, duration_sec_actual: 600}),
        session(%{burpee_count_actual: 100, duration_sec_actual: 900})
      ]

      assert Levels.level_for_type(sessions, :six_count) == :level_1c
    end

    test "sessions of the wrong type are ignored" do
      sessions = [session(%{burpee_type: :navy_seal, burpee_count_actual: 200})]
      assert Levels.level_for_type(sessions, :six_count) == :level_1a
    end

    test "exactly at threshold qualifies" do
      sessions = [session(%{burpee_count_actual: 50, duration_sec_actual: 1200})]
      assert Levels.level_for_type(sessions, :six_count) == :level_1b
    end

    test "navy_seal thresholds are separate from six_count" do
      sessions = [session(%{burpee_type: :navy_seal, burpee_count_actual: 20})]
      assert Levels.level_for_type(sessions, :navy_seal) == :level_1b
      assert Levels.level_for_type(sessions, :six_count) == :level_1a
    end
  end

  describe "next_landmark/2" do
    test "returns level_1b when at level_1a" do
      assert Levels.next_landmark([], :six_count) == %{
               level: :level_1b,
               burpee_count_required: 50
             }
    end

    test "returns the level directly above current" do
      sessions = [session(%{burpee_count_actual: 50, duration_sec_actual: 600})]

      assert Levels.next_landmark(sessions, :six_count) == %{
               level: :level_1c,
               burpee_count_required: 100
             }
    end

    test "returns nil when graduated" do
      sessions = [session(%{burpee_count_actual: 325, duration_sec_actual: 600})]
      assert Levels.next_landmark(sessions, :six_count) == nil
    end

    test "navy_seal thresholds are correct" do
      sessions = [session(%{burpee_type: :navy_seal, burpee_count_actual: 20})]

      assert Levels.next_landmark(sessions, :navy_seal) == %{
               level: :level_1c,
               burpee_count_required: 40
             }
    end
  end

  describe "landmark_achieved?/3" do
    test "true when a qualifying session meets the threshold" do
      sessions = [session(%{burpee_count_actual: 50, duration_sec_actual: 600})]
      assert Levels.landmark_achieved?(sessions, :six_count, :level_1b) == true
    end

    test "false when one rep short" do
      sessions = [session(%{burpee_count_actual: 49, duration_sec_actual: 600})]
      assert Levels.landmark_achieved?(sessions, :six_count, :level_1b) == false
    end

    test "false when session exceeds 1200s even with enough reps" do
      sessions = [session(%{burpee_count_actual: 50, duration_sec_actual: 1201})]
      assert Levels.landmark_achieved?(sessions, :six_count, :level_1b) == false
    end

    test "false with no sessions" do
      assert Levels.landmark_achieved?([], :six_count, :level_1b) == false
    end
  end

  describe "landmark_history/1" do
    test "returns empty list with no sessions" do
      assert Levels.landmark_history([]) == []
    end

    test "entries are sorted chronologically" do
      sessions = [
        session(%{
          id: 1,
          burpee_type: :six_count,
          burpee_count_actual: 100,
          duration_sec_actual: 900,
          inserted_at: ~U[2026-02-01 12:00:00Z]
        }),
        session(%{
          id: 2,
          burpee_type: :six_count,
          burpee_count_actual: 50,
          duration_sec_actual: 600,
          inserted_at: ~U[2026-01-15 12:00:00Z]
        })
      ]

      history = Levels.landmark_history(sessions)
      dates = Enum.map(history, & &1.date_unlocked)
      assert dates == Enum.sort(dates)
    end

    test "records only the first session that achieves a landmark" do
      sessions = [
        session(%{
          id: 1,
          burpee_count_actual: 50,
          duration_sec_actual: 600,
          inserted_at: ~U[2026-01-01 12:00:00Z]
        }),
        session(%{
          id: 2,
          burpee_count_actual: 60,
          duration_sec_actual: 600,
          inserted_at: ~U[2026-02-01 12:00:00Z]
        })
      ]

      history = Levels.landmark_history(sessions)
      entry = Enum.find(history, &(&1.level == :level_1b and &1.burpee_type == :six_count))
      assert entry.session_id == 1
    end

    test "covers both burpee types" do
      sessions = [
        session(%{burpee_type: :six_count, burpee_count_actual: 50}),
        session(%{burpee_type: :navy_seal, burpee_count_actual: 20})
      ]

      types = sessions |> Levels.landmark_history() |> Enum.map(& &1.burpee_type) |> Enum.uniq()
      assert :six_count in types
      assert :navy_seal in types
    end
  end
end
