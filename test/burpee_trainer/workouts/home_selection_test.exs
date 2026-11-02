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

  test "switching away from a coached workout drops its explanation", %{user: u, slot: slot} do
    scope = Scope.for_user(u)
    {:ok, original} = Workouts.ensure_home_selection(scope, slot)
    coached = fitting_plan(u, slot)

    {:ok, selected} =
      Workouts.select_planned_workout(scope, original, {:plan, coached.id}, "Repeat this pace.")

    replacement = fitting_plan(u, slot)
    assert {:ok, switched} = Workouts.select_home_workout(scope, selected, replacement.id)
    assert switched.rationale == nil
    assert {:ok, ^switched} = Workouts.ensure_home_selection(scope, slot)
  end

  for type <- [:six_count, :navy_seal] do
    test "an established athlete gets a twenty-minute #{type} fallback", %{user: u, slot: slot} do
      free_form_session_fixture(u, %{
        completed_at: DateTime.add(DateTime.utc_now(:second), -8, :day)
      })

      slot = %{slot | burpee_type: unquote(type), duration_sec: 1200}
      assert {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
      assert selected.plan.target_duration_sec == 1200
      assert selected.plan.burpee_type == unquote(type)
      assert :ok = Workouts.verify_plan_content(selected.plan)
      assert {:ok, ^selected} = Workouts.ensure_home_selection(Scope.for_user(u), slot)
    end
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
