defmodule BurpeeTrainer.WorkoutsGamificationTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.{Goals, Workouts}

  import BurpeeTrainer.Fixtures

  defp event_types(events), do: Enum.map(events, & &1.type)

  describe "session_milestones/3" do
    test "first session records personal bests and celebrates them" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count"})

      session =
        session_from_plan_fixture(user, plan, %{
          "burpee_count_actual" => 100,
          "duration_sec_actual" => 600
        })

      events = Workouts.session_milestones(user, session, DateTime.to_date(session.inserted_at))
      types = event_types(events)

      assert :session_pushup_pr in types
      assert :week_pushup_pr in types

      stats = Workouts.gamification_stats(user)
      # six-count: 1 push-up per burpee
      assert stats.best_session_pushups == 100
      assert stats.best_week_pushups == 100
    end

    test "a navy seal session scores three push-ups per burpee" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "navy_seal"})

      session =
        session_from_plan_fixture(user, plan, %{
          "burpee_count_actual" => 40,
          "duration_sec_actual" => 600
        })

      Workouts.session_milestones(user, session, DateTime.to_date(session.inserted_at))

      assert Workouts.gamification_stats(user).best_session_pushups == 120
    end

    test "achieving a goal before its deadline emits an early goal_reached event" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count"})
      goal = goal_fixture(user, %{"burpee_count_target" => 70})

      session =
        session_from_plan_fixture(user, plan, %{
          "burpee_count_actual" => 80,
          "duration_sec_actual" => 1200
        })

      events = Workouts.session_milestones(user, session, DateTime.to_date(session.inserted_at))

      goal_event = Enum.find(events, &(&1.type == :goal_reached))
      assert goal_event
      assert goal_event.value.deadline == :early
      assert goal_event.value.target == 70

      assert Goals.get_goal!(user, goal.id).status == :achieved
    end

    test "a later, weaker session in a new week is quiet" do
      user = user_fixture()

      # Free-form sessions are used here because only they accept an
      # inserted_at override (plan sessions are always stamped "now").
      strong =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 120,
          "duration_sec_actual" => 600,
          "inserted_at" => ~U[2026-01-05 12:00:00Z]
        })

      Workouts.session_milestones(user, strong, ~D[2026-01-05])

      weak =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 10,
          "duration_sec_actual" => 600,
          "inserted_at" => ~U[2026-01-13 12:00:00Z]
        })

      events = Workouts.session_milestones(user, weak, ~D[2026-01-13])

      assert events == []
    end
  end

  describe "current_week_pushups/2" do
    test "sums this week's push-ups, weighting navy seal triple" do
      user = user_fixture()
      today = ~D[2026-01-07]

      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 50,
        "duration_sec_actual" => 600,
        "inserted_at" => ~U[2026-01-06 12:00:00Z]
      })

      free_form_session_fixture(user, %{
        "burpee_type" => "navy_seal",
        "burpee_count_actual" => 20,
        "duration_sec_actual" => 600,
        "inserted_at" => ~U[2026-01-07 12:00:00Z]
      })

      assert Workouts.current_week_pushups(user, today) == 50 + 60
    end
  end
end
