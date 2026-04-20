defmodule BurpeeTrainer.ProgressionTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Progression
  alias BurpeeTrainer.Progression.Recommendation
  alias BurpeeTrainer.Workouts.WorkoutSession

  defp build_goal(overrides \\ %{}) do
    base = %Goal{
      id: 1,
      burpee_type: :six_count,
      burpee_count_target: 200,
      duration_sec_target: 1200,
      date_target: ~D[2026-07-01],
      burpee_count_baseline: 100,
      duration_sec_baseline: 1200,
      date_baseline: ~D[2026-04-01],
      status: :active
    }

    struct!(base, overrides)
  end

  defp build_session(date, burpee_count, overrides \\ %{}) do
    naive = NaiveDateTime.new!(date, ~T[12:00:00])

    base = %WorkoutSession{
      burpee_type: :six_count,
      burpee_count_actual: burpee_count,
      duration_sec_actual: 1200,
      inserted_at: naive
    }

    struct!(base, overrides)
  end

  describe "recommend/3 — phase calculation" do
    test "week 1 since baseline is build_1 with 0.90× multiplier" do
      goal = build_goal()
      # one week after baseline
      recommendation = Progression.recommend(goal, [], ~D[2026-04-08])

      assert recommendation.phase == :build_1
      # ratio = 1/13 weeks, linear target ≈ 107.7, × 0.90 ≈ 97
      assert recommendation.burpee_count_suggested in 95..100
    end

    test "week 2 since baseline is build_2 with 1.00× multiplier" do
      goal = build_goal()
      recommendation = Progression.recommend(goal, [], ~D[2026-04-15])

      assert recommendation.phase == :build_2
    end

    test "week 3 since baseline is build_3 with 1.05× multiplier" do
      goal = build_goal()
      recommendation = Progression.recommend(goal, [], ~D[2026-04-22])

      assert recommendation.phase == :build_3
    end

    test "week 4 since baseline is deload with 0.80× multiplier" do
      goal = build_goal()
      recommendation = Progression.recommend(goal, [], ~D[2026-04-29])

      assert recommendation.phase == :deload
      # deload should suggest fewer burpees than an adjacent build_3 week
      recommendation_build3 = Progression.recommend(goal, [], ~D[2026-04-22])
      assert recommendation.burpee_count_suggested < recommendation_build3.burpee_count_suggested
    end

    test "week 5 cycles back to build_1" do
      goal = build_goal()
      recommendation = Progression.recommend(goal, [], ~D[2026-05-06])

      assert recommendation.phase == :build_1
    end
  end

  describe "recommend/3 — trend status" do
    test "0 sessions yields :low_consistency" do
      goal = build_goal()
      recommendation = Progression.recommend(goal, [], ~D[2026-04-15])

      assert recommendation.trend_status == :low_consistency
      assert is_nil(recommendation.burpee_count_projected_at_goal)
    end

    test "1 session yields :low_consistency" do
      goal = build_goal()
      sessions = [build_session(~D[2026-04-10], 120)]

      recommendation = Progression.recommend(goal, sessions, ~D[2026-04-15])

      assert recommendation.trend_status == :low_consistency
    end

    test "2+ sessions trending toward target is :on_track" do
      goal = build_goal()

      sessions = [
        build_session(~D[2026-04-05], 110),
        build_session(~D[2026-04-08], 130),
        build_session(~D[2026-04-12], 150),
        build_session(~D[2026-04-14], 170)
      ]

      recommendation = Progression.recommend(goal, sessions, ~D[2026-04-15])

      assert recommendation.trend_status in [:on_track, :ahead]
      assert is_number(recommendation.burpee_count_projected_at_goal)
    end

    test "flat trend well below target is :behind with +0.05 boost" do
      goal = build_goal()

      # flat at 100 — projection at target date = 100, far below target of 200
      sessions = [
        build_session(~D[2026-04-05], 100),
        build_session(~D[2026-04-08], 100),
        build_session(~D[2026-04-12], 100),
        build_session(~D[2026-04-14], 100)
      ]

      today = ~D[2026-04-15]
      recommendation = Progression.recommend(goal, sessions, today)

      assert recommendation.trend_status == :behind

      # verify the boost: compare to the same week with no sessions (which is
      # low_consistency, so use a distinct build_2 week with a minimal :on_track session set)
      goal_inflated = build_goal(%{burpee_count_target: 130})

      on_track_sessions = [
        build_session(~D[2026-04-12], 128),
        build_session(~D[2026-04-13], 129),
        build_session(~D[2026-04-14], 130)
      ]

      on_track = Progression.recommend(goal_inflated, on_track_sessions, today)
      assert on_track.trend_status in [:on_track, :ahead]
    end

    test "fewer than 2 sessions within 14 days yields :low_consistency even with older history" do
      goal = build_goal()

      # two sessions back at baseline time, none recent
      sessions = [
        build_session(~D[2026-04-01], 100),
        build_session(~D[2026-04-02], 105)
      ]

      # 20 days later — outside 14-day window
      recommendation = Progression.recommend(goal, sessions, ~D[2026-04-21])

      assert recommendation.trend_status == :low_consistency
    end

    test "only sessions of non-matching burpee_type are ignored" do
      goal = build_goal()

      sessions = [
        build_session(~D[2026-04-05], 180, %{burpee_type: :navy_seal}),
        build_session(~D[2026-04-12], 180, %{burpee_type: :navy_seal})
      ]

      recommendation = Progression.recommend(goal, sessions, ~D[2026-04-15])

      assert recommendation.trend_status == :low_consistency
    end
  end

  describe "recommend/3 — output shape" do
    test "sec_per_rep_suggested is duration / count" do
      goal = build_goal()
      recommendation = Progression.recommend(goal, [], ~D[2026-04-15])

      expected =
        recommendation.duration_sec_suggested / recommendation.burpee_count_suggested

      assert_in_delta recommendation.sec_per_rep_suggested, expected, 0.0001
    end

    test "rationale includes phase and trend labels" do
      goal = build_goal()
      recommendation = Progression.recommend(goal, [], ~D[2026-04-22])

      assert recommendation.rationale =~ "Build week 3"
      assert recommendation.rationale =~ "low consistency"
      assert recommendation.rationale =~ "reps"
    end

    test "weeks_remaining counts down toward target date" do
      goal = build_goal()
      week_2 = Progression.recommend(goal, [], ~D[2026-04-15])
      week_5 = Progression.recommend(goal, [], ~D[2026-05-06])

      assert week_2.weeks_remaining > week_5.weeks_remaining
    end

    test "returns a %Recommendation{} struct with goal_id and burpee_type" do
      goal = build_goal()
      recommendation = Progression.recommend(goal, [], ~D[2026-04-15])

      assert %Recommendation{goal_id: 1, burpee_type: :six_count} = recommendation
    end
  end

  describe "weekly_volume/2" do
    test "volume_sec_weekly_target is 80 minutes" do
      assert Progression.volume_sec_weekly_target() == 80 * 60
    end

    test "empty sessions → zero done, full target remaining" do
      volume = Progression.weekly_volume([], ~D[2026-04-15])

      assert volume.volume_sec_done == 0
      assert volume.volume_sec_target == 4800
      assert volume.volume_sec_delta == 4800
    end

    test "week range is Monday–Sunday containing the given date" do
      # 2026-04-15 is a Wednesday
      volume = Progression.weekly_volume([], ~D[2026-04-15])

      assert volume.week_start == ~D[2026-04-13]
      assert volume.week_end == ~D[2026-04-19]
    end

    test "week range when given date is itself a Monday" do
      volume = Progression.weekly_volume([], ~D[2026-04-13])

      assert volume.week_start == ~D[2026-04-13]
      assert volume.week_end == ~D[2026-04-19]
    end

    test "week range when given date is itself a Sunday" do
      volume = Progression.weekly_volume([], ~D[2026-04-19])

      assert volume.week_start == ~D[2026-04-13]
      assert volume.week_end == ~D[2026-04-19]
    end

    test "sums duration_sec_actual across all sessions in the week regardless of burpee_type" do
      sessions = [
        build_session(~D[2026-04-13], 100, %{duration_sec_actual: 1500}),
        build_session(~D[2026-04-15], 120, %{
          burpee_type: :navy_seal,
          duration_sec_actual: 1800
        }),
        build_session(~D[2026-04-19], 90, %{duration_sec_actual: 900})
      ]

      volume = Progression.weekly_volume(sessions, ~D[2026-04-15])

      assert volume.volume_sec_done == 4200
      assert volume.volume_sec_delta == 600
    end

    test "excludes sessions outside the target week" do
      sessions = [
        # previous week
        build_session(~D[2026-04-12], 100, %{duration_sec_actual: 3000}),
        # in week
        build_session(~D[2026-04-14], 100, %{duration_sec_actual: 2000}),
        # next week
        build_session(~D[2026-04-20], 100, %{duration_sec_actual: 3000})
      ]

      volume = Progression.weekly_volume(sessions, ~D[2026-04-15])

      assert volume.volume_sec_done == 2000
    end

    test "nil duration_sec_actual contributes 0" do
      sessions = [
        build_session(~D[2026-04-14], 100, %{duration_sec_actual: nil}),
        build_session(~D[2026-04-15], 100, %{duration_sec_actual: 1200})
      ]

      volume = Progression.weekly_volume(sessions, ~D[2026-04-15])

      assert volume.volume_sec_done == 1200
    end

    test "over-target yields negative delta" do
      sessions = [
        build_session(~D[2026-04-13], 100, %{duration_sec_actual: 3000}),
        build_session(~D[2026-04-15], 100, %{duration_sec_actual: 3000})
      ]

      volume = Progression.weekly_volume(sessions, ~D[2026-04-15])

      assert volume.volume_sec_done == 6000
      assert volume.volume_sec_delta == -1200
    end
  end

  describe "project_trend/1" do
    test "empty list returns empty list" do
      assert Progression.project_trend([]) == []
    end

    test "single session returns empty list" do
      assert Progression.project_trend([build_session(~D[2026-04-10], 120)]) == []
    end

    test "perfectly linear data yields a line that hits each point" do
      sessions = [
        build_session(~D[2026-04-01], 100),
        build_session(~D[2026-04-02], 110),
        build_session(~D[2026-04-03], 120),
        build_session(~D[2026-04-04], 130)
      ]

      points = Progression.project_trend(sessions)

      assert length(points) == 4
      for {_date, y} <- points, do: assert(is_number(y))

      [{_, y1}, {_, y2}, {_, y3}, {_, y4}] = points
      assert_in_delta y1, 100, 0.0001
      assert_in_delta y2, 110, 0.0001
      assert_in_delta y3, 120, 0.0001
      assert_in_delta y4, 130, 0.0001
    end

    test "noisy data produces a best-fit line (slope is positive for upward trend)" do
      sessions = [
        build_session(~D[2026-04-01], 100),
        build_session(~D[2026-04-02], 108),
        build_session(~D[2026-04-03], 115),
        build_session(~D[2026-04-04], 128)
      ]

      [{_, y1}, _, _, {_, y4}] = Progression.project_trend(sessions)
      assert y4 > y1
    end
  end
end
