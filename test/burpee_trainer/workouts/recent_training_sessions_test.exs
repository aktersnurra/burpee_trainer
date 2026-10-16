defmodule BurpeeTrainer.Workouts.RecentTrainingSessionsTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  test "recent coach history is bounded to sixteen completed non-warmup snapshots" do
    user = user_fixture()

    for offset <- 1..17 do
      completed_at = DateTime.add(DateTime.utc_now(:second), -offset * 60, :second)

      free_form_session_fixture(user, %{
        "burpee_count_actual" => offset,
        "duration_sec_actual" => 60,
        "completed_at" => completed_at
      })
    end

    _warmup =
      free_form_session_fixture(user, %{
        "tags" => "warmup",
        "completed_at" => DateTime.add(DateTime.utc_now(:second), -30, :second)
      })

    sessions = Workouts.list_recent_training_sessions(BurpeeTrainer.Accounts.Scope.for_user(user))
    assert length(sessions) == 16
    assert Enum.all?(sessions, &(&1.state == :completed and &1.tags != "warmup"))
  end
end
