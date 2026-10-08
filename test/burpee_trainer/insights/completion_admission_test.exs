defmodule BurpeeTrainer.Insights.CompletionAdmissionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.PlanNextWorkoutJob
  alias BurpeeTrainer.Insights.NarrateJob

  for worker <- [PlanNextWorkoutJob, NarrateJob] do
    @worker worker
    test "failed #{@worker} admission rolls back completion, goal and BOTH jobs, allowing real retry" do
      scope = scope_fixture()

      goal =
        goal_fixture(scope.user, %{
          burpee_type: :six_count,
          burpee_count_target: 30,
          duration_sec_target: 1200,
          date_target: Date.add(Date.utc_today(), 10),
          burpee_count_baseline: 10,
          duration_sec_baseline: 120,
          date_baseline: Date.utc_today()
        })

      plan = plan_fixture(scope.user)
      {:ok, started} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())
      worker = Oban.Worker.to_string(@worker)

      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TEMP TRIGGER refuse_owned_admission BEFORE INSERT ON oban_jobs WHEN NEW.worker = '#{worker}' BEGIN SELECT RAISE(ABORT, 'CHECK constraint failed: attempt_range'); END",
        []
      )

      assert {:error, %{code: :completion_jobs_unavailable}} =
               Workouts.complete_session(
                 scope,
                 started.id,
                 %{burpee_count_actual: 30, duration_sec_actual: 1200},
                 :timed
               )

      assert Workouts.get_session(scope, started.id).state == :started
      assert Repo.get!(BurpeeTrainer.Goals.Goal, goal.id).status == :active
      assert Repo.aggregate(Oban.Job, :count) == 0
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER refuse_owned_admission", [])

      assert {:ok, session} =
               Workouts.complete_session(
                 scope,
                 started.id,
                 %{burpee_count_actual: 30, duration_sec_actual: 1200},
                 :timed
               )

      assert session.state == :completed
      assert Repo.get!(BurpeeTrainer.Goals.Goal, goal.id).status == :achieved

      assert Enum.sort(Enum.map(Repo.all(Oban.Job), & &1.worker)) ==
               Enum.sort(Enum.map([PlanNextWorkoutJob, NarrateJob], &Oban.Worker.to_string/1))
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
