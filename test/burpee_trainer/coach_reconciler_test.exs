defmodule BurpeeTrainer.CoachReconcilerTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.{Accounts, CoachReconciler, Repo, Workouts}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan}

  @now ~U[2025-09-01 12:00:00Z]
  test "startup and explicit periodic scans page users and restore fallback-backed desired state" do
    users = [user_fixture(), user_fixture()]
    parent = self()

    page_query = fn
      nil ->
        send(parent, {:page, nil})
        users

      cursor ->
        send(parent, {:page, cursor})
        []
    end

    reconciler =
      start_reconciler(user_page_query: page_query)

    await_idle(reconciler)
    assert_receive {:page, nil}
    assert_receive {:page, cursor}
    assert cursor == List.last(users).id

    for user <- users do
      recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)
      assert_fallback_startable(user, recommendation)
    end

    Repo.delete_all(CoachRecommendation)
    send(reconciler, :periodic_scan)
    await_idle(reconciler)
    assert Repo.aggregate(CoachRecommendation, :count) == 2

    Repo.delete_all(CoachRecommendation)
    CoachReconciler.scan_now()
    await_idle(reconciler)
    assert Repo.aggregate(CoachRecommendation, :count) == 2

    first_user = List.first(users)
    Repo.delete_all(from(r in CoachRecommendation, where: r.user_id == ^first_user.id))
    assert :ok = CoachReconciler.wake(first_user.id, :retry)
    await_idle(reconciler)
    assert Repo.get_by!(CoachRecommendation, user_id: first_user.id)
  end

  test "public reconciliation creates the local Monday fallback from its injected clock" do
    user = user_fixture()
    monday = ~U[2025-09-08 00:00:00Z]
    reconciler = start_reconciler(now: fn -> monday end, user_page_query: paged_users([user]))

    await_idle(reconciler)

    assert Repo.get_by!(CoachRecommendation,
             user_id: user.id,
             slot_key: "2025-09-08:standard"
           )
  end

  test "public reconciliation uses the DST local date for its fallback slot" do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "America/New_York")
    spring_midnight = ~U[2025-03-09 05:00:00Z]

    reconciler =
      start_reconciler(now: fn -> spring_midnight end, user_page_query: paged_users([user]))

    await_idle(reconciler)

    recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)
    assert recommendation.slot_date == ~D[2025-03-09]
  end

  test "an actual stale scheduled transition has no persisted effect after timezone wake" do
    user = user_fixture()
    now = ~U[2025-09-01 12:00:00Z]
    reconciler = start_reconciler(now: fn -> now end, user_page_query: paged_users([user]))

    await_idle(reconciler)
    stale = :sys.get_state(reconciler).date_timers[user.id]
    original = Repo.get_by!(CoachRecommendation, user_id: user.id)

    {:ok, _user} = Accounts.update_timezone(user, "America/Los_Angeles")
    assert :ok = CoachReconciler.wake(user.id, :timezone_changed)
    await_idle(reconciler)

    send(reconciler, {:date_transition, user.id, stale.token, stale.transition_at})
    _ = :sys.get_state(reconciler)

    assert Repo.aggregate(CoachRecommendation, :count) == 1
    assert Repo.reload!(original) == original

    refute Repo.get_by(CoachRecommendation,
             user_id: user.id,
             slot_key: "2025-09-02:standard"
           )

    assert Repo.aggregate(BurpeeTrainer.Workouts.WorkoutSession, :count) == 0
  end

  test "scan repairs invalid selections while preserving a pending draft" do
    user = user_fixture()
    archived = plan_fixture(user)
    unavailable_video = video_fixture(%{available: false})

    {:ok, recommendation} =
      Workouts.ensure_recommendation(user, %{
        slot_key: "2025-09-01:standard",
        slot_date: ~D[2025-09-01],
        rationale: "Fallback"
      })

    pending_draft = workout_plan_draft_fixture(user, %{name: "Pending candidate"})

    recommendation =
      recommendation
      |> Ecto.Changeset.change(pending_draft_id: pending_draft.id)
      |> Repo.update!()

    {:ok, _archived} = Workouts.archive_plan(user, archived.id)

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: archived.id, selected_workout_video_id: nil]
    )

    reconciler = start_reconciler(user_page_query: paged_users([user]))

    await_idle(reconciler)
    assert_repaired_selection(recommendation, pending_draft.id)

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: nil, selected_workout_video_id: unavailable_video.id]
    )

    CoachReconciler.scan_now()
    await_idle(reconciler)
    assert_repaired_selection(recommendation, pending_draft.id)

    Ecto.Adapters.SQL.query!(Repo, "PRAGMA defer_foreign_keys = ON")
    missing_plan_id = Repo.aggregate(WorkoutPlan, :max, :id) + 10_000

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: missing_plan_id, selected_workout_video_id: nil]
    )

    CoachReconciler.scan_now()
    await_idle(reconciler)
    assert_repaired_selection(recommendation, pending_draft.id)

    missing_video_id = unavailable_video.id + 10_000

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: nil, selected_workout_video_id: missing_video_id]
    )

    CoachReconciler.scan_now()
    await_idle(reconciler)
    assert_repaired_selection(recommendation, pending_draft.id)
  end

  defp start_reconciler(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, unique_name(:coach_tasks))
    name = Keyword.get(opts, :name, CoachReconciler)

    start_supervised!(
      Supervisor.child_spec({Task.Supervisor, name: task_supervisor}, id: task_supervisor)
    )

    reconciler_opts =
      opts
      |> Keyword.put(:task_supervisor, task_supervisor)
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:now, fn -> @now end)
      |> Keyword.put_new(:scan_interval_ms, :infinity)

    start_supervised!(Supervisor.child_spec({CoachReconciler, reconciler_opts}, id: name))
  end

  defp paged_users(users) do
    fn
      nil -> users
      _cursor -> []
    end
  end

  defp await_idle(reconciler) do
    state = :sys.get_state(reconciler)

    case {Map.values(state.in_flight), :queue.is_empty(state.queue)} do
      {[], true} ->
        :ok

      {tasks, _queue_empty?} ->
        refs = Enum.map(tasks, fn %{pid: pid} -> {pid, Process.monitor(pid)} end)

        Enum.each(refs, fn {pid, ref} ->
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        end)

        _ = :sys.get_state(reconciler)
        await_idle(reconciler)
    end
  end

  defp assert_fallback_startable(user, recommendation) do
    assert_fallback_selection(recommendation)

    assert {:ok, _session} =
             Workouts.start_plan(
               user,
               recommendation.selected_workout_plan_id,
               Ecto.UUID.generate()
             )
  end

  defp assert_repaired_selection(recommendation, pending_draft_id) do
    repaired = Repo.reload(recommendation)
    assert repaired.pending_draft_id == pending_draft_id
    assert_fallback_selection(repaired)
  end

  defp assert_fallback_selection(recommendation) do
    fallback = Repo.get!(WorkoutPlan, recommendation.selected_workout_plan_id)
    assert fallback.origin == :built_in
    assert fallback.state == :published
    assert is_nil(recommendation.selected_workout_video_id)
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive, :monotonic])}")
  end
end
