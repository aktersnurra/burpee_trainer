defmodule BurpeeTrainer.Coach.WeekStartJobTest do
  use BurpeeTrainer.DataCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{PlanNextWorkoutJob, WeekStartJob}
  alias BurpeeTrainer.Repo

  @monday ~U[2026-11-02 00:15:00Z]
  @wednesday ~U[2026-11-04 00:15:00Z]

  test "the first day of a week plans its workout once" do
    user = user_fixture()

    assert :ok = WeekStartJob.plan_due(@monday)
    assert [job] = all_enqueued(worker: PlanNextWorkoutJob)
    assert job.args == %{"user_id" => user.id, "slot_key" => "2026-11-02:standard"}

    # A slot already planned, by this job or after a session, is not planned again.
    Repo.update!(Ecto.Changeset.change(job, state: "completed"))
    assert :ok = WeekStartJob.plan_due(@monday)
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "other days and owners without the coach plan nothing" do
    user_fixture()
    {:ok, _} = BurpeeTrainer.Accounts.put_coach_enabled(user_fixture(), false)

    assert :ok = WeekStartJob.plan_due(@wednesday)
    assert :ok = WeekStartJob.plan_due(@monday |> DateTime.add(-1, :day))
    assert all_enqueued(worker: PlanNextWorkoutJob) |> length() == 0

    assert :ok = WeekStartJob.plan_due(@monday)
    assert [_one] = all_enqueued(worker: PlanNextWorkoutJob)
  end
end
