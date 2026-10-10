defmodule BurpeeTrainer.Workouts.HomeReturningEvidenceTest do
  use BurpeeTrainer.DataCase, async: false

  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Home, Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession, WorkoutVideo}

  for evidence <- [:draft, :archived, :prior_recommendation, :corrupt_draft_pin] do
    @evidence evidence

    test "#{evidence} evidence gets a genuine fallback or repaired pin" do
      scope = scope_fixture()
      now = DateTime.utc_now(:second)
      {:ok, slot} = Policy.required_slot(scope, now)
      prior = arrange(scope, slot, @evidence)
      assert_owned_evidence(scope, @evidence)
      assert {:ok, facts} = Home.facts(scope, now)
      assert {:start, selection} = Home.state(facts)
      assert selection.plan.user_id == nil
      assert selection.plan.state == :published
      assert :ok = Workouts.verify_plan_content(selection.plan)
      assert Repo.get!(CoachRecommendation, selection.recommendation_id).user_id == scope.user.id
      assert_next_revision(selection.recommendation_id, selection.home_revision, prior)
      before = rows()
      assert Workouts.current_home_selection(scope, slot) == selection
      assert rows() == before
      assert {:ok, session} = Workouts.start_home_workout(scope, selection, Ecto.UUID.generate())
      assert session.program_snapshot == selection.plan.program_json
      assert session.content_hash == selection.plan.content_hash
    end

    test "#{evidence} evidence without fallback chooses and explicitly recovers a shared plan" do
      scope = scope_fixture()
      now = DateTime.utc_now(:second)
      {:ok, slot} = Policy.required_slot(scope, now)
      prior = arrange(scope, slot, @evidence)
      archive_fallbacks(now)
      before = rows()
      assert {:ok, facts} = Home.facts(scope, now)
      assert :choose = Home.state(facts)
      assert facts.selection == nil
      assert rows() == before
      assert_owned_evidence(scope, @evidence)
      # New shared built-ins never become the fallback, so Home stays in choose and the
      # canonical one is chosen explicitly even beside a corrupt one.
      corrupt_fallback = shared_source(scope, true)
      assert {:error, _} = Workouts.verify_plan_content(corrupt_fallback)
      source = shared_source(scope)
      assert {:ok, choose} = Home.facts(scope, now)
      assert :choose = Home.state(choose)
      assert {:ok, selected} = Workouts.recover_home_workout_selection(scope, slot, source.id)
      assert selected.plan.id == source.id
      assert_next_revision(selected.recommendation_id, selected.home_revision, prior)
      assert {:ok, session} = Workouts.start_home_workout(scope, selected, Ecto.UUID.generate())
      assert session.program_snapshot == source.program_json
      assert session.content_hash == source.content_hash
    end

    test "#{evidence} evidence authorizes recovery's independently rechecked transaction" do
      scope = scope_fixture()
      now = DateTime.utc_now(:second)
      {:ok, slot} = Policy.required_slot(scope, now)
      arrange(scope, slot, @evidence)
      archive_fallbacks(now)
      video = video_fixture()
      assert_owned_evidence(scope, @evidence)

      assert {:ok, session} =
               Workouts.start_recovery_home_video(scope, slot, video.id, Ecto.UUID.generate())

      assert session.user_id == scope.user.id
      assert session.workout_video_id == video.id
    end

    test "#{evidence} evidence without fallback starts canonical recovery video and replays" do
      scope = scope_fixture()
      now = DateTime.utc_now(:second)
      {:ok, slot} = Policy.required_slot(scope, now)
      prior = arrange(scope, slot, @evidence)
      archive_fallbacks(now)
      video = video_fixture()
      before = rows()
      assert {:ok, facts} = Home.facts(scope, now)
      assert :choose = Home.state(facts)
      assert rows() == before
      assert_owned_evidence(scope, @evidence)
      token = Ecto.UUID.generate()
      assert {:ok, session} = Workouts.start_recovery_home_video(scope, slot, video.id, token)
      assert session.source_kind == :video
      assert session.plan_id == nil
      assert session.workout_video_id == video.id
      assert is_map(session.video_snapshot)
      assert is_binary(session.content_hash)

      recommendation =
        Repo.get_by!(CoachRecommendation, user_id: scope.user.id, slot_key: slot.slot_key)

      assert recommendation.selected_workout_video_id == video.id
      assert recommendation.selected_workout_plan_id == nil
      assert recommendation.home_workout_plan_id == nil
      assert_next_revision(recommendation.id, recommendation.home_revision, prior)
      after_start = rows()
      assert {:ok, ^session} = Workouts.start_recovery_home_video(scope, slot, video.id, token)
      assert rows() == after_start
    end
  end

  test "another user's evidence never lets a fresh user recover with their plan" do
    other = scope_fixture()
    now = DateTime.utc_now(:second)
    {:ok, other_slot} = Policy.required_slot(other, now)
    arrange(other, other_slot, :corrupt_draft_pin)
    archive_fallbacks(now)
    source = plan_fixture(other.user)
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, now)
    before = rows()

    assert {:ok, facts} = Home.facts(scope, now)
    assert facts.selection == nil
    assert facts.started_session == nil
    assert :choose = Home.state(facts)
    assert {:error, _} = Workouts.recover_home_workout_selection(scope, slot, source.id)
    assert rows() == before
  end

  test "a valid owned draft pin remains recognized without repair or publication" do
    scope = scope_fixture()
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(scope, now)
    draft = workout_plan_draft_fixture(scope.user)
    recommendation = recommendation(scope, slot, draft.id)

    recommendation
    |> Ecto.Changeset.change(home_workout_plan_id: draft.id, home_revision: 4)
    |> Repo.update!()

    before = rows()
    assert {:ok, facts} = Home.facts(scope, now)
    assert {:start, selected} = Home.state(facts)
    assert selected.plan == draft
    assert selected.home_revision == 4
    assert {:error, _} = Workouts.recover_home_workout_selection(scope, slot, shared_source_id())
    assert rows() == before
  end

  defp arrange(scope, _slot, :draft) do
    workout_plan_draft_fixture(scope.user)
    nil
  end

  defp arrange(scope, _slot, :archived) do
    plan = plan_fixture(scope.user)
    assert {:ok, _} = Workouts.archive_plan(scope, plan.id)
    nil
  end

  defp arrange(scope, slot, :prior_recommendation) do
    recommendation(
      scope,
      %{slot | slot_key: "prior:" <> slot.slot_key, slot_date: Date.add(slot.slot_date, -7)},
      shared_source_id()
    )

    nil
  end

  defp arrange(scope, slot, :corrupt_draft_pin) do
    draft = workout_plan_draft_fixture(scope.user)
    draft |> Ecto.Changeset.change(content_hash: String.duplicate("a", 64)) |> Repo.update!()

    recommendation(scope, slot, shared_source_id())
    |> Ecto.Changeset.change(home_workout_plan_id: draft.id, home_revision: 7)
    |> Repo.update!()
  end

  defp assert_next_revision(_id, _revision, nil), do: :ok

  defp assert_next_revision(id, revision, %CoachRecommendation{} = prior) do
    assert id == prior.id
    assert revision == prior.home_revision + 1
  end

  defp recommendation(scope, slot, plan_id) do
    %CoachRecommendation{user_id: scope.user.id}
    |> CoachRecommendation.changeset(
      Map.merge(Map.take(slot, [:slot_key, :slot_date]), %{selected_workout_plan_id: plan_id})
    )
    |> Repo.insert!()
  end

  defp assert_owned_evidence(scope, evidence) do
    assert Repo.aggregate(from(s in WorkoutSession, where: s.user_id == ^scope.user.id), :count) ==
             0

    assert Repo.exists?(from(p in WorkoutPlan, where: p.user_id == ^scope.user.id)) ==
             (evidence != :prior_recommendation)

    assert Repo.exists?(from(r in CoachRecommendation, where: r.user_id == ^scope.user.id)) ==
             evidence in [:prior_recommendation, :corrupt_draft_pin]
  end

  defp shared_source(scope, corrupt? \\ false) do
    source = workout_plan_draft_fixture(scope_fixture().user)
    source = if corrupt?, do: %{source | content_hash: String.duplicate("a", 64)}, else: source
    # Shared source is catalog setup, never actor-owned returning evidence.
    shared =
      %WorkoutPlan{origin: :built_in, state: :draft}
      |> WorkoutPlan.new_draft_changeset(
        Map.take(source, [
          :name,
          :definition_json,
          :program_json,
          :content_hash,
          :burpee_type,
          :target_reps,
          :target_duration_sec
        ])
      )
      |> Repo.insert!()
      |> WorkoutPlan.publish_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

    assert shared.user_id != scope.user.id
    shared
  end

  defp shared_source_id do
    Repo.one!(
      from(p in WorkoutPlan,
        where: is_nil(p.user_id) and p.state == :published,
        order_by: p.id,
        limit: 1
      )
    ).id
  end

  defp archive_fallbacks(now) do
    Repo.all(from(p in WorkoutPlan, where: is_nil(p.user_id) and p.state == :published))
    |> Enum.each(fn p -> p |> WorkoutPlan.archive_changeset(now) |> Repo.update!() end)
  end

  defp rows do
    {Repo.all(from(r in CoachRecommendation, order_by: r.id)),
     Repo.all(from(p in WorkoutPlan, order_by: p.id)),
     Repo.all(from(s in WorkoutSession, order_by: s.id)),
     Repo.all(from(v in WorkoutVideo, order_by: v.id))}
  end
end
