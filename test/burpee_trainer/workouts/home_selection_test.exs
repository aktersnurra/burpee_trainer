defmodule BurpeeTrainer.Workouts.HomeSelectionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Error}

  setup do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    %{user: user, slot: slot}
  end

  test "reload is stable and another tab cannot overwrite selection", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(u, slot)
    assert {:ok, ^a} = Workouts.ensure_home_selection(u, slot)
    plan = plan_fixture(u)
    {:ok, b} = Workouts.select_home_workout(u, a, plan.id)
    assert b.home_revision == a.home_revision + 1

    assert {:error, %Error{code: :home_selection_changed}} =
             Workouts.select_home_workout(u, a, a.plan.id)

    assert {:ok, ^b} = Workouts.ensure_home_selection(u, slot)
  end

  test "foreign selection is rejected without changing the pin", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(u, slot)
    foreign = plan_fixture(user_fixture())
    assert {:error, _} = Workouts.select_home_workout(u, a, foreign.id)
    assert {:ok, ^a} = Workouts.ensure_home_selection(u, slot)
  end

  test "archived pin falls back with a new revision", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(u, slot)
    plan = plan_fixture(u)
    {:ok, b} = Workouts.select_home_workout(u, a, plan.id)
    {:ok, _} = Workouts.archive_plan(u, plan.id)
    {:ok, c} = Workouts.ensure_home_selection(u, slot)
    assert c.plan.origin == :built_in
    assert c.home_revision > b.home_revision
    assert {:error, _} = Workouts.verify_home_selection(u, b)
  end

  test "legacy automatic video is normalized without starting it", %{user: u, slot: slot} do
    {:ok, r} = Workouts.ensure_recommendation(u, Map.take(slot, [:slot_key, :slot_date]))
    video = video_fixture()
    {:ok, _} = Workouts.select_recommendation(u, r.id, {:video, video.id}, "Legacy")
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)
    assert shown.plan.origin == :built_in
    assert Repo.get!(CoachRecommendation, r.id).selected_workout_video_id == nil
    assert Workouts.current_started_session(u) == nil
  end

  test "late candidate and explicit selection preserve each other's identities", %{
    user: u,
    slot: slot
  } do
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)

    d =
      workout_plan_draft_fixture(u, %{
        target_duration_sec: slot.duration_sec,
        burpee_type: Atom.to_string(slot.burpee_type),
        target_reps: 10
      })

    candidate =
      Repo.get!(CoachRecommendation, shown.recommendation_id)
      |> Ecto.Changeset.change(pending_draft_id: d.id)
      |> Repo.update!()

    {:ok, reopened} = Workouts.ensure_home_selection(u, slot)
    assert reopened.plan.id == shown.plan.id
    assert reopened.home_revision == shown.home_revision
    alternative = plan_fixture(u)
    {:ok, selected} = Workouts.select_home_workout(u, reopened, alternative.id)

    assert Repo.get!(CoachRecommendation, selected.recommendation_id).pending_draft_id ==
             candidate.pending_draft_id
  end

  test "initial pending draft is pinned and verification detects content changes", %{
    user: u,
    slot: slot
  } do
    {:ok, r} = Workouts.ensure_recommendation(u, Map.take(slot, [:slot_key, :slot_date]))
    draft = workout_plan_draft_fixture(u)
    r |> Ecto.Changeset.change(pending_draft_id: draft.id) |> Repo.update!()
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)
    assert shown.plan.id == draft.id
    assert {:ok, ^draft} = Workouts.verify_home_selection(u, shown)
    draft |> Ecto.Changeset.change(name: "Changed content") |> Repo.update!()
    assert {:error, %Error{code: :draft_stale}} = Workouts.verify_home_selection(u, shown)
  end

  test "verification rejects foreign users and an obsolete slot", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)
    assert {:ok, plan} = Workouts.verify_home_selection(u, shown)
    assert plan == shown.plan

    assert {:error, %Error{code: :home_selection_changed}} =
             Workouts.verify_home_selection(user_fixture(), shown)

    Repo.get!(CoachRecommendation, shown.recommendation_id)
    |> Ecto.Changeset.change(slot_key: "obsolete-slot")
    |> Repo.update!()

    assert {:error, %Error{code: :home_selection_changed}} =
             Workouts.verify_home_selection(u, shown)
  end

  test "only the pending draft can be explicitly selected", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)
    draft = workout_plan_draft_fixture(u)
    assert {:error, _} = Workouts.select_home_workout(u, shown, draft.id)

    Repo.get!(CoachRecommendation, shown.recommendation_id)
    |> Ecto.Changeset.change(pending_draft_id: draft.id)
    |> Repo.update!()

    assert {:ok, selected} = Workouts.select_home_workout(u, shown, draft.id)
    assert selected.plan.id == draft.id
    assert {:ok, ^draft} = Workouts.verify_home_selection(u, selected)
  end

  test "wrong-source token and stale pin cannot start", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)
    other = plan_fixture(u)
    token = Ecto.UUID.generate()
    {:ok, existing} = Workouts.start_plan(u, other.id, token)

    assert {:error, %Error{code: :start_token_source_mismatch}} =
             Workouts.start_home_workout(u, shown, token)

    assert Workouts.current_started_session(u).id == existing.id
    {:ok, changed} = Workouts.select_home_workout(u, shown, other.id)
    assert changed.home_revision > shown.home_revision

    assert {:error, %Error{code: :home_selection_changed}} =
             Workouts.start_home_workout(u, shown, Ecto.UUID.generate())
  end

  test "exact duplicate Start reuses one snapshot", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)
    token = Ecto.UUID.generate()
    {:ok, first} = Workouts.start_home_workout(u, shown, token)
    assert {:ok, again} = Workouts.start_home_workout(u, shown, token)
    assert again.id == first.id
    assert first.program_snapshot == shown.plan.program_json
  end

  test "video selection starts directly and does not change the pin", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)
    video = video_fixture(%{burpee_count: 100})
    token = Ecto.UUID.generate()
    {:ok, session} = Workouts.start_home_video(u, shown, video.id, token)
    assert {:ok, duplicate} = Workouts.start_home_video(u, shown, video.id, token)
    assert duplicate.id == session.id

    assert {:error, %Error{code: :session_in_progress}} =
             Workouts.start_home_workout(u, shown, Ecto.UUID.generate())

    assert {:error, %Error{code: :session_in_progress}} =
             Workouts.start_home_video(u, shown, video.id, Ecto.UUID.generate())

    video |> Ecto.Changeset.change(name: "Changed video") |> Repo.update!()

    assert {:error, %Error{code: :start_token_source_mismatch}} =
             Workouts.start_home_video(u, shown, video.id, token)

    assert session.source_kind == :video
    assert session.workout_video_id == video.id
    assert session.plan_id == nil
    assert {:ok, same} = Workouts.ensure_home_selection(u, slot)
    assert same.plan.id == shown.plan.id
    assert same.home_revision == shown.home_revision
  end
end
