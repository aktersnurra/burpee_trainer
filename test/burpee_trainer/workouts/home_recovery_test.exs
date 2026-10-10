defmodule BurpeeTrainer.Workouts.HomeRecoveryTest do
  use BurpeeTrainer.DataCase, async: false
  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Home, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession, WorkoutVideo}

  setup do
    user = user_fixture()
    scope = Scope.for_user(user)
    now = DateTime.utc_now(:second)
    free_form_session_fixture(user, %{completed_at: DateTime.add(now, -10, :day)})
    archive_fallbacks(now)
    {:ok, slot} = Policy.required_slot(scope, now)
    assert {:ok, facts} = Home.facts(scope, now)
    assert :choose = Home.state(facts)
    %{user: user, scope: scope, slot: slot}
  end

  test "explicit owned choice pins a real recommendation and starts normally", c do
    plan = plan_fixture(c.user)
    assert {:ok, selection} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
    assert selection.plan.id == plan.id
    assert selection.home_revision == 1
    assert Workouts.current_home_selection(c.scope, c.slot) == selection
    assert Repo.get!(CoachRecommendation, selection.recommendation_id).user_id == c.user.id
    assert {:ok, session} = Workouts.start_home_workout(c.scope, selection, Ecto.UUID.generate())
    assert session.program_snapshot == plan.program_json
    assert session.content_hash == plan.content_hash
  end

  test "explicit shared canonical choice works when the fallback row is corrupt", c do
    source = plan_fixture(c.user)
    # A corrupt fallback cannot be repaired or substituted by this command.
    corrupt =
      copied_plan(%{steady_fallback() | content_hash: String.duplicate("a", 64)}, nil, :built_in)

    shared = copied_plan(source, nil, :built_in)
    assert {:error, _} = Workouts.verify_plan_content(corrupt)
    assert {:ok, facts} = Home.facts(c.scope, DateTime.utc_now(:second))
    assert :choose = Home.state(facts)
    assert {:ok, selected} = Workouts.recover_home_workout_selection(c.scope, c.slot, shared.id)
    assert selected.plan.id == shared.id
    assert selected.plan.user_id == nil
  end

  test "foreign archived draft corrupt missing and malformed choices have no effects", c do
    foreign = plan_fixture(user_fixture())
    archived = plan_fixture(c.user)
    archived |> WorkoutPlan.archive_changeset(DateTime.utc_now(:second)) |> Repo.update!()
    draft = workout_plan_draft_fixture(c.user)
    corrupt = corrupt_plan(c.user)

    for id <- [foreign.id, archived.id, draft.id, corrupt.id, -1, nil, "bad", %{}] do
      before = rows()
      assert {:error, _} = Workouts.recover_home_workout_selection(c.scope, c.slot, id)
      assert rows() == before
    end
  end

  test "first use without history or owned published evidence cannot recover", c do
    fresh = scope_fixture()
    {:ok, slot} = Policy.required_slot(fresh, DateTime.utc_now(:second))
    plan = plan_fixture(c.user)
    before = rows()
    assert {:error, _} = Workouts.recover_home_workout_selection(fresh, slot, plan.id)

    assert {:error, _} =
             Workouts.start_recovery_home_video(
               fresh,
               slot,
               video_fixture().id,
               Ecto.UUID.generate()
             )

    # Video fixture insertion is catalog setup, not a recovery effect.
    assert Repo.all(CoachRecommendation) == elem(before, 0)
    assert Repo.all(WorkoutSession) == elem(before, 2)
  end

  test "owned published plan alone is sufficient choose evidence", c do
    owner = scope_fixture()
    plan = plan_fixture(owner.user)
    {:ok, slot} = Policy.required_slot(owner, DateTime.utc_now(:second))
    assert {:ok, selected} = Workouts.recover_home_workout_selection(owner, slot, plan.id)
    assert selected.plan.id == plan.id
    refute selected.recommendation_id == nil
    assert c.scope.user.id != owner.user.id
  end

  test "stale malformed foreign slot and done week states reject without effects", c do
    plan = plan_fixture(c.user)

    for slot <- [
          nil,
          %{},
          %{c.slot | slot_key: "stale"},
          %{c.slot | slot_date: Date.add(c.slot.slot_date, -1)},
          %{c.slot | home_state: :done_today},
          %{c.slot | home_state: :week_complete}
        ] do
      before = rows()
      assert {:error, _} = Workouts.recover_home_workout_selection(c.scope, slot, plan.id)
      assert rows() == before
    end

    free_form_session_fixture(c.user, %{completed_at: DateTime.utc_now(:second)})
    before = rows()
    assert {:error, _} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
    assert rows() == before
  end

  test "an intervening valid pin cannot be replaced and video cannot bypass it", c do
    plan = plan_fixture(c.user)
    alternative = plan_fixture(c.user)
    video = video_fixture()
    assert {:ok, winner} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
    before = rows()
    assert {:error, _} = Workouts.recover_home_workout_selection(c.scope, c.slot, alternative.id)

    assert {:error, _} =
             Workouts.start_recovery_home_video(c.scope, c.slot, video.id, Ecto.UUID.generate())

    assert rows() == before
    assert Workouts.current_home_selection(c.scope, c.slot) == winner
  end

  test "another active session prevents plan and video recovery without recommendation leaks",
       c do
    plan = plan_fixture(c.user)
    video = video_fixture()
    {:ok, _} = Workouts.start_video(c.scope, video.id, Ecto.UUID.generate())
    before = rows()
    assert {:error, _} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)

    assert {:error, _} =
             Workouts.start_recovery_home_video(c.scope, c.slot, video.id, Ecto.UUID.generate())

    assert rows() == before
  end

  test "available fallback means this is not choose and must not recover", c do
    plan = plan_fixture(c.user)
    copied_plan(steady_fallback(), nil, :built_in)
    before = rows()
    assert {:error, _} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
    assert rows() == before
  end

  test "video recovery uses actual video recommendation snapshot and exact replay", c do
    video = video_fixture()
    token = Ecto.UUID.generate()
    assert {:ok, started} = Workouts.start_recovery_home_video(c.scope, c.slot, video.id, token)
    assert started.source_kind == :video
    assert started.plan_id == nil
    assert started.workout_video_id == video.id
    assert is_map(started.video_snapshot)
    assert is_binary(started.content_hash)

    recommendation =
      Repo.get_by!(CoachRecommendation, user_id: c.user.id, slot_key: c.slot.slot_key)

    assert recommendation.selected_workout_video_id == video.id
    assert recommendation.selected_workout_plan_id == nil
    assert recommendation.home_workout_plan_id == nil
    before = rows()
    assert {:ok, ^started} = Workouts.start_recovery_home_video(c.scope, c.slot, video.id, token)
    assert rows() == before
  end

  test "conflicting replay token source or canonical hash and unavailable video reject", c do
    video = video_fixture()
    other = video_fixture()
    token = Ecto.UUID.generate()
    {:ok, _} = Workouts.start_recovery_home_video(c.scope, c.slot, video.id, token)
    before = rows()
    assert {:error, _} = Workouts.start_recovery_home_video(c.scope, c.slot, other.id, token)

    assert {:error, _} =
             Workouts.start_recovery_home_video(c.scope, c.slot, video.id, Ecto.UUID.generate())

    assert rows() == before
    video |> Ecto.Changeset.change(duration_sec: video.duration_sec + 1) |> Repo.update!()
    changed = rows()
    assert {:error, _} = Workouts.start_recovery_home_video(c.scope, c.slot, video.id, token)
    assert rows() == changed
  end

  test "malformed unavailable and noncanonical videos leave no recommendation", c do
    unavailable = video_fixture(%{available: false})
    malformed = video_fixture() |> Ecto.Changeset.change(duration_sec: 0) |> Repo.update!()

    for id <- [unavailable.id, malformed.id, -1, nil, "bad", %{}] do
      before = rows()

      assert {:error, _} =
               Workouts.start_recovery_home_video(c.scope, c.slot, id, Ecto.UUID.generate())

      assert rows() == before
    end

    video = video_fixture()

    for token <- [nil, "bad", %{}] do
      before = rows()
      assert {:error, _} = Workouts.start_recovery_home_video(c.scope, c.slot, video.id, token)
      assert rows() == before
    end
  end

  test "real recovery writes participate in an enclosing lifecycle rollback", c do
    video = video_fixture()
    before = rows()

    assert {:error, :forced_recovery_failure} =
             Repo.immediate_transaction(fn ->
               assert {:ok, started} =
                        Workouts.start_recovery_home_video(
                          c.scope,
                          c.slot,
                          video.id,
                          Ecto.UUID.generate()
                        )

               assert Repo.get!(WorkoutSession, started.id) == started

               recommendation =
                 Repo.get_by!(CoachRecommendation, user_id: c.user.id, slot_key: c.slot.slot_key)

               assert recommendation.selected_workout_video_id == video.id
               assert recommendation.home_revision == 1
               assert recommendation.home_workout_plan_id == nil
               Repo.rollback(:forced_recovery_failure)
             end)

    assert rows() == before
    assert Repo.aggregate(CoachRecommendation, :count) == 0
  end

  test "actual choose with an unpinned valid recommendation and absent fallback recovers", c do
    plan = plan_fixture(c.user)

    recommendation =
      %CoachRecommendation{user_id: c.user.id}
      |> CoachRecommendation.changeset(
        Map.merge(Map.take(c.slot, [:slot_key, :slot_date]), %{selected_workout_plan_id: plan.id})
      )
      |> Repo.insert!()

    assert {:ok, facts} = Home.facts(c.scope, DateTime.utc_now(:second))
    assert :choose = Home.state(facts)
    assert {:ok, selected} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
    assert selected.recommendation_id == recommendation.id
    assert selected.home_revision == 1
  end

  test "an intervening real ensured pin rejects even exact successful video replay", c do
    video = video_fixture()
    token = Ecto.UUID.generate()
    assert {:ok, _} = Workouts.start_recovery_home_video(c.scope, c.slot, video.id, token)
    copied_plan(steady_fallback(), nil, :built_in)
    assert {:ok, selected} = Workouts.ensure_home_selection(c.scope, c.slot)
    before = rows()
    assert {:error, _} = Workouts.start_recovery_home_video(c.scope, c.slot, video.id, token)
    assert rows() == before
    assert Workouts.current_home_selection(c.scope, c.slot) == selected
  end

  test "a recommendation uniqueness failure is typed and leaves every row unchanged", c do
    plan = plan_fixture(c.user)

    %CoachRecommendation{user_id: c.user.id}
    |> CoachRecommendation.changeset(%{
      slot_key: c.slot.slot_key,
      slot_date: Date.add(c.slot.slot_date, -1),
      selected_workout_plan_id: plan.id
    })
    |> Repo.insert!()

    before = rows()
    assert {:error, _} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
    assert rows() == before
  end

  test "an existing invalid pointer recovers using its actual next revision", c do
    plan = plan_fixture(c.user)
    archived = Repo.one!(from(p in WorkoutPlan, where: is_nil(p.user_id), limit: 1))

    recommendation =
      %CoachRecommendation{user_id: c.user.id}
      |> CoachRecommendation.changeset(
        Map.merge(Map.take(c.slot, [:slot_key, :slot_date]), %{
          selected_workout_plan_id: archived.id
        })
      )
      |> Repo.insert!()
      |> Ecto.Changeset.change(home_workout_plan_id: archived.id, home_revision: 7)
      |> Repo.update!()

    assert Workouts.current_home_selection(c.scope, c.slot) == nil
    assert {:ok, selected} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
    assert selected.recommendation_id == recommendation.id
    assert selected.home_revision == 8
    assert selected.plan.id == plan.id
    before = rows()
    assert {:error, _} = Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
    assert rows() == before
  end

  test "stale or malformed video slot never writes", c do
    video = video_fixture()

    for slot <- [
          nil,
          %{},
          %{c.slot | slot_key: "stale"},
          %{c.slot | slot_date: Date.add(c.slot.slot_date, -1)},
          %{c.slot | home_state: :done_today}
        ] do
      before = rows()

      assert {:error, _} =
               Workouts.start_recovery_home_video(c.scope, slot, video.id, Ecto.UUID.generate())

      assert rows() == before
    end
  end

  test "foreign user's valid selection is neither consulted nor changed", c do
    other = scope_fixture()
    plan = plan_fixture(other.user)
    {:ok, other_slot} = Policy.required_slot(other, DateTime.utc_now(:second))

    assert {:ok, other_selection} =
             Workouts.recover_home_workout_selection(other, other_slot, plan.id)

    own_plan = plan_fixture(c.user)

    assert {:ok, own_selection} =
             Workouts.recover_home_workout_selection(c.scope, c.slot, own_plan.id)

    assert own_selection.recommendation_id != other_selection.recommendation_id
    assert Workouts.current_home_selection(other, other_slot) == other_selection
  end

  test "two concurrent videos create exactly one real session", c do
    video = video_fixture()
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              Workouts.start_recovery_home_video(c.scope, c.slot, video.id, Ecto.UUID.generate())
          end
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await/1)
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, _}] = Enum.filter(results, &match?({:error, _}, &1))
    assert Workouts.current_started_session(c.scope) == winner
    assert Repo.aggregate(CoachRecommendation, :count) == 1
    assert Repo.aggregate(from(s in WorkoutSession, where: s.state == :started), :count) == 1
  end

  test "two concurrent choices preserve exactly one winning revision", c do
    plans = [plan_fixture(c.user), plan_fixture(c.user)]
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      Enum.map(plans, fn plan ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Workouts.recover_home_workout_selection(c.scope, c.slot, plan.id)
          end
        end)
      end)

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await/1)
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, _}] = Enum.filter(results, &match?({:error, _}, &1))
    assert Workouts.current_home_selection(c.scope, c.slot) == winner
    assert winner.home_revision == 1
    assert Repo.aggregate(CoachRecommendation, :count) == 1
  end

  defp archive_fallbacks(now) do
    Repo.all(
      from(p in WorkoutPlan,
        where: is_nil(p.user_id) and p.origin == :built_in and p.state == :published
      )
    )
    |> Enum.each(fn plan -> plan |> WorkoutPlan.archive_changeset(now) |> Repo.update!() end)
  end

  # The archived fallback row; republishing a copy makes the fallback available again.
  defp steady_fallback do
    Repo.one!(
      from(p in WorkoutPlan,
        where: is_nil(p.user_id) and p.name == "Built-in Steady 10",
        order_by: [asc: p.id],
        limit: 1
      )
    )
  end

  defp copied_plan(source, owner, origin) do
    fields = [
      :name,
      :definition_json,
      :program_json,
      :content_hash,
      :burpee_type,
      :target_reps,
      :target_duration_sec
    ]

    %WorkoutPlan{user_id: owner, origin: origin, state: :draft}
    |> WorkoutPlan.new_draft_changeset(Map.take(source, fields))
    |> Repo.insert!()
    |> WorkoutPlan.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp corrupt_plan(user) do
    draft = workout_plan_draft_fixture(user)

    draft =
      draft |> Ecto.Changeset.change(content_hash: String.duplicate("a", 64)) |> Repo.update!()

    draft |> WorkoutPlan.publish_changeset(DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp rows do
    {Repo.all(from(r in CoachRecommendation, order_by: r.id)),
     Repo.all(from(p in WorkoutPlan, order_by: p.id)),
     Repo.all(from(s in WorkoutSession, order_by: s.id)),
     Repo.all(from(v in WorkoutVideo, order_by: v.id))}
  end
end
