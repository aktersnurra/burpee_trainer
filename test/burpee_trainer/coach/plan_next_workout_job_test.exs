defmodule BurpeeTrainer.Coach.PlanNextWorkoutJobTest do
  use BurpeeTrainer.DataCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{PlanNextWorkoutJob, Policy}
  alias BurpeeTrainer.Workouts

  test "completion schedules one uniquely owned next-local-slot job" do
    scope = scope_fixture(%{"timezone" => "Etc/UTC"})
    session_from_plan_fixture(scope.user, plan_fixture(scope.user))

    assert [%{args: %{"user_id" => id, "slot_key" => key}, scheduled_at: at}] =
             all_enqueued(worker: PlanNextWorkoutJob)

    assert id == scope.user.id
    assert DateTime.compare(at, DateTime.utc_now()) == :gt
    {:ok, slot} = Policy.required_slot(scope, at)
    assert key == slot.slot_key
    assert :ok = PlanNextWorkoutJob.enqueue(scope)
    assert length(all_enqueued(worker: PlanNextWorkoutJob)) == 1
  end

  test "disabled provider and stale slot leave deterministic selection untouched" do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, before} = Workouts.ensure_home_selection(scope, slot)

    assert {:cancel, :provider_unavailable} =
             perform_job(PlanNextWorkoutJob, %{
               "user_id" => scope.user.id,
               "slot_key" => slot.slot_key
             })

    assert {:cancel, :slot_changed} =
             perform_job(PlanNextWorkoutJob, %{"user_id" => scope.user.id, "slot_key" => "stale"})

    assert {:ok, after_selection} = Workouts.ensure_home_selection(scope, slot)
    assert before == after_selection
  end

  test "next local boundary is resolved through real DST policy and UTC conversion" do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "America/Los_Angeles")
    scope = BurpeeTrainer.Accounts.Scope.for_user(user)
    now = ~U[2026-03-08 19:00:00Z]

    Repo.insert!(%BurpeeTrainer.Workouts.WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      display_name_snapshot: "Logged",
      workout_type_snapshot: :six_count,
      burpee_type: :six_count,
      burpee_count_actual: 10,
      duration_sec_actual: 1200,
      completed_at: now,
      capture_mode: :logged
    })

    assert {:ok, slot, ~U[2026-03-09 07:00:00Z] = at} = PlanNextWorkoutJob.target_slot(scope, now)
    assert {:ok, actual} = Policy.required_slot(scope, at)
    assert slot == actual
    assert slot.home_state == :workout_needed

    {:ok, earlier} =
      BurpeeTrainer.UserTime.resolve_local(~D[2026-03-08], ~T[00:00:00], user.timezone)

    assert DateTime.diff(at, earlier) == 23 * 3600
  end

  test "a completed weekly quota never manufactures an eligible next day" do
    scope = scope_fixture()
    now = ~U[2026-10-07 12:00:00Z]

    Repo.insert!(%BurpeeTrainer.Workouts.WorkoutSession{
      user_id: scope.user.id,
      state: :completed,
      source_kind: :manual,
      display_name_snapshot: "Logged",
      workout_type_snapshot: :six_count,
      burpee_type: :six_count,
      burpee_count_actual: 100,
      duration_sec_actual: 4800,
      completed_at: now,
      capture_mode: :logged
    })

    assert {:ok, slot, at} = PlanNextWorkoutJob.target_slot(scope, now)
    assert slot.home_state == :week_complete
    assert {:ok, actual} = Policy.required_slot(scope, at)
    assert actual == slot
  end
end
