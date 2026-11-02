defmodule BurpeeTrainer.Insights.CompletionAdmissionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  import ExUnit.CaptureLog
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.{PlanNextWorkoutJob, SummaryJob}
  alias BurpeeTrainer.Insights.NarrateJob

  @workers [PlanNextWorkoutJob, NarrateJob, SummaryJob]

  test "a failed admission of any one job still saves the completion and admits the others" do
    for worker <- @workers do
      scope = scope_fixture()

      goal =
        goal_fixture(scope.user, %{
          burpee_type: :six_count,
          burpee_count_target: 30,
          date_target: Date.add(Date.utc_today(), 10),
          burpee_count_baseline: 10,
          duration_sec_baseline: 120,
          date_baseline: Date.utc_today()
        })

      plan = plan_fixture(scope.user)
      {:ok, started} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())

      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TEMP TRIGGER refuse_owned_admission BEFORE INSERT ON oban_jobs WHEN NEW.worker = '#{Oban.Worker.to_string(worker)}' BEGIN SELECT RAISE(ABORT, 'CHECK constraint failed: attempt_range'); END",
        []
      )

      log =
        capture_log(fn ->
          assert {:ok, session} =
                   Workouts.complete_session(
                     scope,
                     started.id,
                     %{burpee_count_actual: 30, duration_sec_actual: 1200},
                     :timed
                   )

          send(self(), {:completed, session})
        end)

      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER refuse_owned_admission", [])

      assert_received {:completed, session}
      assert session.state == :completed
      assert Workouts.get_session(scope, started.id).state == :completed
      assert Repo.get!(BurpeeTrainer.Goals.Goal, goal.id).status == :achieved
      assert log =~ "completion_job_not_admitted"

      admitted =
        for job <- Repo.all(Oban.Job), job.args["user_id"] == scope.user.id, do: job.worker

      assert Enum.sort(admitted) ==
               Enum.sort(for other <- @workers, other != worker, do: Oban.Worker.to_string(other)),
             inspect(worker)
    end
  end

  test "nested immediate transactions share admission and outer rollback" do
    scope = scope_fixture()
    session = free_form_session_fixture(scope.user)

    assert {:error, :outer_preview} =
             Repo.immediate_transaction(fn ->
               assert Repo.in_transaction?()
               assert {:ok, _} = NarrateJob.enqueue(scope, session)
               assert :ok = PlanNextWorkoutJob.enqueue(scope)
               assert Repo.aggregate(Oban.Job, :count) == 2
               Repo.rollback(:outer_preview)
             end)

    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
