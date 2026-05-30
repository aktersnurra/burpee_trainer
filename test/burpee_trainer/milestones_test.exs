defmodule BurpeeTrainer.MilestonesTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Milestones

  # A baseline input where nothing is a milestone. Individual tests override
  # only the keys relevant to the event under test.
  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        level_before: :level_1b,
        level_after: :level_1b,
        week_pushups_before: 50,
        week_pushups_after: 55,
        best_week_pushups_before: 100,
        session_pushups: 10,
        best_session_pushups_before: 100,
        session_pace: 6.0,
        session_qualifies_pace?: false,
        best_pace_before: 4.0,
        lifetime_after: 500,
        lifetime_milestone_before: 0,
        balanced_before?: false,
        balanced_after?: false,
        goal: nil,
        days_since_last: 1
      },
      overrides
    )
  end

  defp types(input), do: input |> Milestones.detect() |> Enum.map(& &1.type)

  test "quiet input produces no events" do
    assert Milestones.detect(base()) == []
  end

  describe "level_up" do
    test "fires when level advances" do
      assert :level_up in types(base(%{level_before: :level_1a, level_after: :level_1b}))
    end

    test "does not fire when level is unchanged" do
      refute :level_up in types(base(%{level_before: :level_2, level_after: :level_2}))
    end

    test "does not fire when level drops (decay)" do
      refute :level_up in types(base(%{level_before: :level_2, level_after: :level_1b}))
    end

    test "carries from/to in the payload" do
      [event] = Milestones.detect(base(%{level_before: :level_1a, level_after: :graduated}))
      assert event == %{type: :level_up, value: %{from: :level_1a, to: :graduated}}
    end
  end

  describe "week_pushup_pr" do
    test "fires on crossover above the stored best" do
      input =
        base(%{week_pushups_before: 90, week_pushups_after: 120, best_week_pushups_before: 100})

      assert :week_pushup_pr in types(input)
    end

    test "does not fire again once already past the best" do
      input =
        base(%{week_pushups_before: 110, week_pushups_after: 130, best_week_pushups_before: 100})

      refute :week_pushup_pr in types(input)
    end

    test "does not fire when still under the best" do
      input =
        base(%{week_pushups_before: 50, week_pushups_after: 80, best_week_pushups_before: 100})

      refute :week_pushup_pr in types(input)
    end
  end

  describe "session_pushup_pr" do
    test "fires when the session beats the best single session" do
      assert :session_pushup_pr in types(
               base(%{session_pushups: 150, best_session_pushups_before: 100})
             )
    end

    test "does not fire when tying or below" do
      refute :session_pushup_pr in types(
               base(%{session_pushups: 100, best_session_pushups_before: 100})
             )
    end
  end

  describe "pace_pr" do
    test "fires for a qualifying faster session" do
      input = base(%{session_qualifies_pace?: true, session_pace: 3.5, best_pace_before: 4.0})
      assert :pace_pr in types(input)
    end

    test "fires for the first qualifying session (no prior best)" do
      input = base(%{session_qualifies_pace?: true, session_pace: 5.0, best_pace_before: nil})
      assert :pace_pr in types(input)
    end

    test "does not fire when the session does not qualify" do
      input = base(%{session_qualifies_pace?: false, session_pace: 1.0, best_pace_before: 4.0})
      refute :pace_pr in types(input)
    end

    test "does not fire when slower than the best" do
      input = base(%{session_qualifies_pace?: true, session_pace: 4.5, best_pace_before: 4.0})
      refute :pace_pr in types(input)
    end
  end

  describe "lifetime_milestone" do
    test "fires when crossing a threshold, reporting the highest crossed" do
      input = base(%{lifetime_after: 6000, lifetime_milestone_before: 0})
      [event] = Milestones.detect(input) |> Enum.filter(&(&1.type == :lifetime_milestone))
      assert event.value == 5_000
    end

    test "does not re-fire a threshold already recorded" do
      input = base(%{lifetime_after: 1200, lifetime_milestone_before: 1000})
      refute :lifetime_milestone in types(input)
    end
  end

  describe "balanced_week" do
    test "fires on crossover into balance" do
      assert :balanced_week in types(base(%{balanced_before?: false, balanced_after?: true}))
    end

    test "does not fire when already balanced" do
      refute :balanced_week in types(base(%{balanced_before?: true, balanced_after?: true}))
    end
  end

  describe "goal_reached" do
    test "fires with the deadline category" do
      goal = %{burpee_type: :six_count, target: 100, deadline: :early}
      assert [%{type: :goal_reached, value: ^goal}] = Milestones.detect(base(%{goal: goal}))
    end

    test "does not fire without a goal" do
      refute :goal_reached in types(base(%{goal: nil}))
    end
  end

  describe "comeback" do
    test "fires after a long enough gap" do
      assert :comeback in types(base(%{days_since_last: Milestones.comeback_days()}))
    end

    test "does not fire for a short gap" do
      refute :comeback in types(base(%{days_since_last: 3}))
    end

    test "does not fire when days_since_last is nil (first ever session)" do
      refute :comeback in types(base(%{days_since_last: nil}))
    end
  end

  test "events are ordered by significance, level_up first" do
    input =
      base(%{
        level_before: :level_1a,
        level_after: :level_1b,
        balanced_before?: false,
        balanced_after?: true,
        days_since_last: 30
      })

    assert types(input) == [:level_up, :balanced_week, :comeback]
  end
end
