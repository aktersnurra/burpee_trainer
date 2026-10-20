defmodule BurpeeTrainer.Workouts.HomeSelectionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Error}

  setup do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    %{user: user, slot: slot}
  end

  test "reload is stable and another tab cannot overwrite selection", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert {:ok, ^a} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    plan = plan_fixture(u)
    {:ok, b} = Workouts.select_home_workout(Scope.for_user(u), a, plan.id)
    assert b.home_revision == a.home_revision + 1

    assert {:error, %Error{code: :home_selection_changed}} =
             Workouts.select_home_workout(Scope.for_user(u), a, a.plan.id)

    assert {:ok, ^b} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
  end

  # Yesterday's slot, chosen by `planned_by`, opened a day ago.
  defp chose_yesterday(u, slot, plan, planned_by) do
    date = Date.add(slot.slot_date, -1)
    key = "#{Date.to_iso8601(date)}:#{slot.strategy}"

    {:ok, r} =
      Workouts.ensure_recommendation(Scope.for_user(u), %{slot_key: key, slot_date: date})

    opened = DateTime.add(DateTime.utc_now(:second), -1, :day)

    r
    |> Ecto.Changeset.change(
      home_workout_plan_id: plan.id,
      home_revision: 1,
      planned_by: planned_by,
      rationale: "Hold yesterday's pace.",
      inserted_at: opened
    )
    |> Repo.update!()
  end

  defp fitting_plan(u, slot),
    do:
      plan_fixture(u, %{
        target_duration_sec: slot.duration_sec,
        burpee_type: Atom.to_string(slot.burpee_type)
      })

  test "a day without training keeps the previous day's workout", %{user: u, slot: slot} do
    plan = fitting_plan(u, slot)
    chose_yesterday(u, slot, plan, :owner)

    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert shown.plan.id == plan.id
    assert Workouts.planned_by(Scope.for_user(u), slot) == :owner

    assert Repo.get!(CoachRecommendation, shown.recommendation_id).rationale ==
             "Hold yesterday's pace."
  end

  test "a session since the previous day's choice plans the day afresh", %{user: u, slot: slot} do
    plan = fitting_plan(u, slot)
    chose_yesterday(u, slot, plan, :coach)

    free_form_session_fixture(u, %{
      completed_at: DateTime.add(DateTime.utc_now(:second), -1, :hour)
    })

    {:ok, slot} = Policy.required_slot(Scope.for_user(u), DateTime.utc_now(:second))

    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert shown.plan.origin == :built_in
    assert Workouts.planned_by(Scope.for_user(u), slot) == nil
  end

  test "a previous workout that no longer fits the slot is not kept", %{user: u, slot: slot} do
    plan = plan_fixture(u, %{target_duration_sec: slot.duration_sec + 60})
    chose_yesterday(u, slot, plan, :owner)

    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert shown.plan.origin == :built_in
  end

  test "foreign selection is rejected without changing the pin", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    foreign = plan_fixture(user_fixture())
    assert {:error, _} = Workouts.select_home_workout(Scope.for_user(u), a, foreign.id)
    assert {:ok, ^a} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
  end

  test "archived pin falls back with a new revision", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    plan = plan_fixture(u)
    {:ok, b} = Workouts.select_home_workout(Scope.for_user(u), a, plan.id)
    {:ok, _} = Workouts.archive_plan(Scope.for_user(u), plan.id)
    {:ok, c} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert c.plan.origin == :built_in
    assert c.home_revision > b.home_revision
    assert {:error, _} = Workouts.verify_home_selection(Scope.for_user(u), b)
  end

  test "legacy automatic video is normalized without starting it", %{user: u, slot: slot} do
    {:ok, r} =
      Workouts.ensure_recommendation(Scope.for_user(u), Map.take(slot, [:slot_key, :slot_date]))

    video = video_fixture()

    _ =
      r
      |> Ecto.Changeset.change(selected_workout_plan_id: nil, selected_workout_video_id: video.id)
      |> Repo.update!()

    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert shown.plan.origin == :built_in
    assert Repo.get!(CoachRecommendation, r.id).selected_workout_video_id == nil
    assert Workouts.current_started_session(Scope.for_user(u)) == nil
  end

  test "late candidate and explicit selection preserve each other's identities", %{
    user: u,
    slot: slot
  } do
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)

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

    {:ok, reopened} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert reopened.plan.id == shown.plan.id
    assert reopened.home_revision == shown.home_revision
    alternative = plan_fixture(u)
    {:ok, selected} = Workouts.select_home_workout(Scope.for_user(u), reopened, alternative.id)

    assert Repo.get!(CoachRecommendation, selected.recommendation_id).pending_draft_id ==
             candidate.pending_draft_id
  end

  test "initial pending draft is pinned and verification detects content changes", %{
    user: u,
    slot: slot
  } do
    {:ok, r} =
      Workouts.ensure_recommendation(Scope.for_user(u), Map.take(slot, [:slot_key, :slot_date]))

    draft = workout_plan_draft_fixture(u)
    r |> Ecto.Changeset.change(pending_draft_id: draft.id) |> Repo.update!()
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert shown.plan.id == draft.id
    assert {:ok, ^draft} = Workouts.verify_home_selection(Scope.for_user(u), shown)
    draft |> Ecto.Changeset.change(name: "Changed content") |> Repo.update!()

    assert {:error, %Error{code: :draft_stale}} =
             Workouts.verify_home_selection(Scope.for_user(u), shown)
  end

  for corruption <- [:name, :events] do
    test "initial pending with corrupt #{corruption} falls back stably", %{user: u, slot: slot} do
      {:ok, r} =
        Workouts.ensure_recommendation(Scope.for_user(u), Map.take(slot, [:slot_key, :slot_date]))

      plan = workout_plan_draft_fixture(u)
      r |> Ecto.Changeset.change(pending_draft_id: plan.id) |> Repo.update!()
      corrupt = corrupt_plan(plan, unquote(corruption))

      assert {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
      assert shown.plan.id != plan.id
      assert shown.plan.origin == :built_in
      assert :ok = Workouts.verify_plan_content(shown.plan)
      assert shown.home_revision == 1
      assert {:ok, ^shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
      assert Repo.reload!(corrupt) == corrupt
    end

    test "pinned pending with corrupt #{corruption} advances revision and rejects stale Start",
         %{
           user: u,
           slot: slot
         } do
      {:ok, r} =
        Workouts.ensure_recommendation(Scope.for_user(u), Map.take(slot, [:slot_key, :slot_date]))

      plan = workout_plan_draft_fixture(u)
      r |> Ecto.Changeset.change(pending_draft_id: plan.id) |> Repo.update!()
      {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
      assert shown.plan.id == plan.id
      corrupt = corrupt_plan(plan, unquote(corruption))

      assert {:ok, fallback} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
      assert fallback.plan.id != plan.id
      assert fallback.plan.origin == :built_in
      assert :ok = Workouts.verify_plan_content(fallback.plan)
      assert fallback.home_revision == shown.home_revision + 1
      assert {:ok, ^fallback} = Workouts.ensure_home_selection(Scope.for_user(u), slot)

      assert {:error, %Error{code: :home_selection_changed}} =
               Workouts.start_home_workout(Scope.for_user(u), shown, Ecto.UUID.generate())

      assert Workouts.current_started_session(Scope.for_user(u)) == nil
      assert Repo.reload!(corrupt) == corrupt
    end
  end

  defp corrupt_plan(plan, :name) do
    plan |> Ecto.Changeset.change(name: "Changed content") |> Repo.update!()
  end

  defp corrupt_plan(plan, :events) do
    definition = Map.put(plan.definition_json, "events", ["malformed"])
    plan |> Ecto.Changeset.change(definition_json: definition) |> Repo.update!()
  end

  test "verification rejects foreign users and an obsolete slot", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert {:ok, plan} = Workouts.verify_home_selection(Scope.for_user(u), shown)
    assert plan == shown.plan

    assert {:error, %Error{code: :home_selection_changed}} =
             Workouts.verify_home_selection(Scope.for_user(user_fixture()), shown)

    Repo.get!(CoachRecommendation, shown.recommendation_id)
    |> Ecto.Changeset.change(slot_key: "obsolete-slot")
    |> Repo.update!()

    assert {:error, %Error{code: :home_selection_changed}} =
             Workouts.verify_home_selection(Scope.for_user(u), shown)
  end

  test "only the pending draft can be explicitly selected", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    draft = workout_plan_draft_fixture(u)
    assert {:error, _} = Workouts.select_home_workout(Scope.for_user(u), shown, draft.id)

    Repo.get!(CoachRecommendation, shown.recommendation_id)
    |> Ecto.Changeset.change(pending_draft_id: draft.id)
    |> Repo.update!()

    assert {:ok, selected} = Workouts.select_home_workout(Scope.for_user(u), shown, draft.id)
    assert selected.plan.id == draft.id
    assert {:ok, ^draft} = Workouts.verify_home_selection(Scope.for_user(u), selected)
  end

  test "wrong-source token and stale pin cannot start", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    other = plan_fixture(u)
    token = Ecto.UUID.generate()
    {:ok, existing} = Workouts.start_plan(Scope.for_user(u), other.id, token)

    assert {:error, %Error{code: :start_token_source_mismatch}} =
             Workouts.start_home_workout(Scope.for_user(u), shown, token)

    assert Workouts.current_started_session(Scope.for_user(u)).id == existing.id
    {:ok, changed} = Workouts.select_home_workout(Scope.for_user(u), shown, other.id)
    assert changed.home_revision > shown.home_revision

    assert {:error, %Error{code: :home_selection_changed}} =
             Workouts.start_home_workout(Scope.for_user(u), shown, Ecto.UUID.generate())
  end

  test "exact duplicate Start reuses one snapshot", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    token = Ecto.UUID.generate()
    {:ok, first} = Workouts.start_home_workout(Scope.for_user(u), shown, token)
    assert {:ok, again} = Workouts.start_home_workout(Scope.for_user(u), shown, token)
    assert again.id == first.id
    assert first.program_snapshot == shown.plan.program_json
  end

  test "video selection starts directly and does not change the pin", %{user: u, slot: slot} do
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    video = video_fixture(%{burpee_count: 100})
    token = Ecto.UUID.generate()
    {:ok, session} = Workouts.start_home_video(Scope.for_user(u), shown, video.id, token)
    assert {:ok, duplicate} = Workouts.start_home_video(Scope.for_user(u), shown, video.id, token)
    assert duplicate.id == session.id

    assert {:error, %Error{code: :session_in_progress}} =
             Workouts.start_home_workout(Scope.for_user(u), shown, Ecto.UUID.generate())

    assert {:error, %Error{code: :session_in_progress}} =
             Workouts.start_home_video(Scope.for_user(u), shown, video.id, Ecto.UUID.generate())

    video |> Ecto.Changeset.change(name: "Changed video") |> Repo.update!()

    assert {:error, %Error{code: :start_token_source_mismatch}} =
             Workouts.start_home_video(Scope.for_user(u), shown, video.id, token)

    assert session.source_kind == :video
    assert session.workout_video_id == video.id
    assert session.plan_id == nil
    assert {:ok, same} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    assert same.plan.id == shown.plan.id
    assert same.home_revision == shown.home_revision
  end
end
