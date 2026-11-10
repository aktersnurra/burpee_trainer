defmodule BurpeeTrainer.Workouts.CurrentLevelTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.{Levels, Workouts}

  defp pair(user, days_ago) do
    at = DateTime.add(DateTime.utc_now(:second), -days_ago, :day)

    for {type, reps} <- [six_count: 50, navy_seal: 20] do
      free_form_session_fixture(user, %{
        burpee_type: Atom.to_string(type),
        burpee_count_actual: reps,
        duration_sec_actual: 1_200,
        completed_at: at
      })
    end
  end

  test "a level reads the same from the recent sessions as from the whole history" do
    for days_ago <- [0, 14, 15, 60] do
      user = user_fixture()
      scope = Scope.for_user(user)
      pair(user, days_ago)
      # An older pair has decayed and must not come back.
      pair(user, 200)

      assert Workouts.current_level(scope) == Levels.current_level(Workouts.list_sessions(scope))
    end
  end

  test "a pair inside its window holds the level" do
    user = user_fixture()
    pair(user, 3)

    assert Workouts.current_level(Scope.for_user(user)) == :level_1b
  end
end
