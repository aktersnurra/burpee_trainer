defmodule BurpeeTrainer.Workouts.RecommendationLifecycleTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan}

  test "accept_candidate publishes a pending compiler-backed draft and clears its pointer" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)
    draft = workout_plan_draft_fixture(user, %{name: "Accepted candidate"})

    recommendation =
      recommendation
      |> Ecto.Changeset.change(pending_draft_id: draft.id)
      |> Repo.update!()

    expected = {:plan, recommendation.selected_workout_plan_id}

    assert {:ok, accepted} =
             Workouts.accept_candidate(
               Scope.for_user(user),
               recommendation.id,
               draft.id,
               expected
             )

    assert is_nil(accepted.pending_draft_id)
    assert accepted.selected_workout_plan_id == draft.id
    assert is_nil(accepted.selected_workout_video_id)
    assert Repo.get!(WorkoutPlan, draft.id).state == :published
  end

  test "accept_candidate re-verifies a corrupt pending draft and rolls back detachment" do
    user = user_fixture()
    {:ok, recommendation} = ensure(user)
    draft = workout_plan_draft_fixture(user, %{name: "Corrupt candidate"})

    original_selection =
      {recommendation.selected_workout_plan_id, recommendation.selected_workout_video_id}

    recommendation =
      recommendation
      |> Ecto.Changeset.change(pending_draft_id: draft.id)
      |> Repo.update!()

    Repo.update_all(from(plan in WorkoutPlan, where: plan.id == ^draft.id),
      set: [content_hash: "corrupt"]
    )

    expected = {:plan, recommendation.selected_workout_plan_id}

    assert {:error, %{code: :infeasible_workout_definition}} =
             Workouts.accept_candidate(
               Scope.for_user(user),
               recommendation.id,
               draft.id,
               expected
             )

    persisted_recommendation = Repo.get!(CoachRecommendation, recommendation.id)
    persisted_draft = Repo.get!(WorkoutPlan, draft.id)

    assert persisted_draft.state == :draft
    assert persisted_recommendation.pending_draft_id == draft.id

    assert {persisted_recommendation.selected_workout_plan_id,
            persisted_recommendation.selected_workout_video_id} == original_selection
  end

  test "pending Home Start rolls back publication and pointer changes on invalid token or corrupt content" do
    {user, recommendation, slot} = attached_home_fixture(user_fixture(), "Atomic candidate")
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(user), slot)

    assert shown.plan.id == recommendation.pending_draft_id
    assert {:error, _} = Workouts.start_home_workout(Scope.for_user(user), shown, "bad-token")

    Repo.update_all(from(plan in WorkoutPlan, where: plan.id == ^shown.plan.id),
      set: [content_hash: "corrupt"]
    )

    assert {:error, _} =
             Workouts.start_home_workout(Scope.for_user(user), shown, Ecto.UUID.generate())

    assert Repo.get!(WorkoutPlan, shown.plan.id).state == :draft
    assert Repo.get!(CoachRecommendation, recommendation.id).pending_draft_id == shown.plan.id
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
  end

  test "pending Home Start publishes, clears the pointer, snapshots content, and is idempotent" do
    {user, recommendation, slot} = attached_home_fixture(user_fixture(), "Start me")
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    token = Ecto.UUID.generate()

    assert {:ok, session} = Workouts.start_home_workout(Scope.for_user(user), shown, token)
    assert {:ok, duplicate} = Workouts.start_home_workout(Scope.for_user(user), shown, token)
    assert duplicate.id == session.id
    assert Repo.get!(WorkoutPlan, shown.plan.id).state == :published

    persisted = Repo.get!(CoachRecommendation, recommendation.id)
    assert persisted.pending_draft_id == nil
    assert persisted.selected_workout_plan_id == shown.plan.id
    assert session.program_snapshot == shown.plan.program_json
    assert session.content_hash == shown.plan.content_hash
  end

  defp ensure(user) do
    Workouts.ensure_recommendation(Scope.for_user(user), %{
      slot_key: "2025-09-01:#{System.unique_integer([:positive])}",
      slot_date: ~D[2025-09-01],
      rationale: "Fallback"
    })
  end

  defp attached_home_fixture(user, name) do
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")

    {:ok, slot} =
      BurpeeTrainer.Coach.Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))

    {:ok, recommendation} =
      Workouts.ensure_recommendation(
        Scope.for_user(user),
        Map.take(slot, [:slot_key, :slot_date])
      )

    draft = workout_plan_draft_fixture(user, %{name: name})

    recommendation =
      recommendation
      |> Ecto.Changeset.change(pending_draft_id: draft.id)
      |> Repo.update!()

    {user, recommendation, slot}
  end
end
