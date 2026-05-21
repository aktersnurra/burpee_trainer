defmodule BurpeeTrainer.CoachTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.Coach
  alias BurpeeTrainer.Coach.Arm
  alias BurpeeTrainer.Repo

  defp make_sessions(user, plan, count) do
    for i <- 1..count do
      session = session_from_plan_fixture(user, plan, %{
        "burpee_count_actual" => 150,
        "duration_sec_actual" => 900
      })
      Repo.update_all(
        from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -i * 3600, :second)]
      )
      session
    end
  end

  describe "baseline/2" do
    test "returns nil when fewer than 5 sessions exist" do
      user = user_fixture()
      assert Coach.baseline(user, :six_count) == nil
    end

    test "returns rolling average of last 5 sessions" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 150})
      make_sessions(user, plan, 5)

      baseline = Coach.baseline(user, :six_count)
      assert baseline != nil
      assert baseline.burpee_count == 150
      assert is_float(baseline.sec_per_burpee)
      assert is_float(baseline.rest_sec)
    end

    test "ignores warmup sessions" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 150})

      # 3 warmup sessions + 2 real = only 2 real, should return nil
      for i <- 1..3 do
        s = session_from_plan_fixture(user, plan, %{"tags" => "warmup", "burpee_count_actual" => 150, "duration_sec_actual" => 900})
        Repo.update_all(from(sess in BurpeeTrainer.Workouts.WorkoutSession, where: sess.id == ^s.id), set: [inserted_at: DateTime.add(DateTime.utc_now(), -i * 3600, :second)])
      end
      for i <- 1..2 do
        s = session_from_plan_fixture(user, plan, %{"burpee_count_actual" => 150, "duration_sec_actual" => 900})
        Repo.update_all(from(sess in BurpeeTrainer.Workouts.WorkoutSession, where: sess.id == ^s.id), set: [inserted_at: DateTime.add(DateTime.utc_now(), -(i + 10) * 3600, :second)])
      end

      assert Coach.baseline(user, :six_count) == nil
    end
  end

  describe "suggest/2" do
    test "returns nil when fewer than 5 sessions" do
      user = user_fixture()
      assert Coach.suggest(user, :six_count) == nil
    end

    test "returns a suggestion map when enough sessions exist" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 150})
      make_sessions(user, plan, 5)

      suggestion = Coach.suggest(user, :six_count)
      assert suggestion != nil
      assert Map.has_key?(suggestion, :burpee_count)
      assert Map.has_key?(suggestion, :sec_per_burpee)
      assert Map.has_key?(suggestion, :rest_sec)
      assert Map.has_key?(suggestion, :dimension)
      assert Map.has_key?(suggestion, :rationale)
      assert is_integer(suggestion.burpee_count)
      assert is_float(suggestion.sec_per_burpee)
      assert is_binary(suggestion.rationale)
    end

    test "suggestion burpee_count is positive" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 150})
      make_sessions(user, plan, 5)

      suggestion = Coach.suggest(user, :six_count)
      assert suggestion.burpee_count > 0
    end
  end

  describe "update_arms/2" do
    test "does not crash when session has no plan_id" do
      user = user_fixture()
      session = %BurpeeTrainer.Workouts.WorkoutSession{
        user_id: user.id,
        burpee_type: :six_count,
        burpee_count_planned: nil,
        burpee_count_actual: 100,
        duration_sec_actual: 600,
        plan_id: nil,
        tags: nil
      }
      assert Coach.update_arms(user, session) == :ok
    end

    test "increments alpha when completion >= 0.8 and arm matches" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 150})
      make_sessions(user, plan, 5)

      # Ensure arms are created
      Coach.suggest(user, :six_count)

      session = session_from_plan_fixture(user, plan, %{
        "burpee_count_planned" => 150,
        "burpee_count_actual" => 150,
        "duration_sec_actual" => 900
      })

      before_arms = Repo.all(from a in Arm, where: a.user_id == ^user.id and a.burpee_type == "six_count")
      Coach.update_arms(user, session)
      after_arms = Repo.all(from a in Arm, where: a.user_id == ^user.id and a.burpee_type == "six_count")

      # At least one arm's alpha or beta changed
      changes = Enum.zip(before_arms, after_arms)
      assert Enum.any?(changes, fn {b, a} -> a.alpha != b.alpha or a.beta != b.beta end)
    end
  end
end
