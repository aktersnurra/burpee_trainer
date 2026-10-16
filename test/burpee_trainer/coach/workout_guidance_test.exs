defmodule BurpeeTrainer.Coach.WorkoutGuidanceTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{Voice, WorkoutGuidance}

  test "authoring speaks in the voice and the rationale never stands in for a workout" do
    scope = scope_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(scope.user, "Etc/UTC")
    prompt = WorkoutGuidance.system_prompt(BurpeeTrainer.Accounts.Scope.for_user(user))

    assert String.starts_with?(prompt, Voice.text())
    assert prompt =~ "say in the rationale what you changed"
    refute prompt =~ "instead of inventing a plan"
    assert prompt =~ "Return only the layout JSON."
  end
end
