defmodule BurpeeTrainer.Insights.NarrateJobTest do
  use BurpeeTrainer.DataCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Insights.NarrateJob
  alias BurpeeTrainer.{Insights, Workouts}

  test "actual completion enqueues unique narration for the owned session" do
    scope = scope_fixture()
    plan = plan_fixture(scope.user)
    {:ok, started} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())

    {:ok, session} =
      Workouts.complete_session(
        scope,
        started.id,
        %{burpee_count_actual: 30, duration_sec_actual: 118},
        :timed
      )

    assert_enqueued(worker: NarrateJob, args: %{user_id: scope.user.id, session_id: session.id})
    assert {:ok, _} = NarrateJob.enqueue(scope, session)
    assert length(all_enqueued(worker: NarrateJob)) == 1
  end

  test "actual job stores fallback with disabled provider and refuses forged ownership" do
    scope = scope_fixture()
    session = free_form_session_fixture(scope.user)
    assert :ok = perform_job(NarrateJob, %{user_id: scope.user.id, session_id: session.id})
    assert Insights.for_session(scope, session.id).source == "fallback"
    foreign = scope_fixture()

    assert {:cancel, :session_not_owned} =
             perform_job(NarrateJob, %{user_id: foreign.user.id, session_id: session.id})

    assert Insights.for_session(foreign, session.id) == nil
  end
end
