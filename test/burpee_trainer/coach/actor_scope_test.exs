defmodule BurpeeTrainer.Coach.ActorScopeTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "Policy accepts persisted Scope and excludes another actor's training credit" do
    owner = scope_fixture()
    other = scope_fixture()
    now = ~U[2026-09-07 12:00:00Z]

    session =
      free_form_session_fixture(other.user, %{completed_at: now, duration_sec_actual: 1200})

    before = Repo.all(WorkoutSession)

    assert {:ok, %{completed_sec: 0, remaining_sec: 4800, home_state: :workout_needed}} =
             Policy.required_slot(owner, now)

    assert {:ok, %{completed_sec: 1200, remaining_sec: 3600, home_state: :done_today}} =
             Policy.required_slot(other, now)

    assert Repo.all(WorkoutSession) == before
    assert Repo.reload!(session) == session
  end
end
