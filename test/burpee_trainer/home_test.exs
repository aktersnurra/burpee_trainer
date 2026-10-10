defmodule BurpeeTrainer.HomeTest do
  use BurpeeTrainer.DataCase, async: false

  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Home, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan}

  @now ~U[2025-09-03 12:00:00Z]
  @monday ~U[2025-09-01 10:00:00Z]

  test "a user with history gets a startable selection" do
    user = user_fixture()
    _plan = plan_fixture(user)

    free_form_session_fixture(user, %{
      completed_at: DateTime.add(DateTime.utc_now(:second), -10, :day)
    })

    assert {:ok, facts} = Home.facts(Scope.for_user(user), DateTime.utc_now(:second))
    assert {:start, %{plan: %{}}} = Home.state(facts)
  end

  test "history-only eligibility ensures a persisted selection" do
    user = user_fixture()
    _history = completed_session(user, @monday)

    assert recommendation_snapshot(user) == []
    assert {:ok, facts} = Home.facts(Scope.for_user(user), @now)
    assert %{recommendation_id: recommendation_id, plan: %{id: plan_id}} = facts.selection

    assert [{^recommendation_id, ^plan_id, _home_plan_id, _pending_draft_id, _revision}] =
             recommendation_snapshot(user)

    assert {:start, %{recommendation_id: ^recommendation_id}} = Home.state(facts)
  end

  test "plan-only eligibility ensures a persisted selection" do
    user = user_fixture()
    _plan = plan_fixture(user)

    assert recommendation_snapshot(user) == []
    assert {:ok, facts} = Home.facts(Scope.for_user(user), @now)
    assert %{recommendation_id: recommendation_id} = facts.selection

    assert [{^recommendation_id, _plan_id, _home_plan_id, _pending_draft_id, _revision}] =
             recommendation_snapshot(user)
  end

  test "another user's started session, selection, history, and plan never appear" do
    owner = user_fixture()
    other = user_fixture()
    _plan = plan_fixture(other)

    free_form_session_fixture(other, %{
      completed_at: DateTime.add(DateTime.utc_now(:second), -10, :day)
    })

    {:ok, selection} =
      Workouts.ensure_home_selection(
        Scope.for_user(other),
        slot(other, DateTime.utc_now(:second))
      )

    {:ok, _started} =
      Workouts.start_home_workout(Scope.for_user(other), selection, Ecto.UUID.generate())

    assert {:ok, facts} = Home.facts(Scope.for_user(owner), DateTime.utc_now(:second))
    assert facts.started_session == nil
    assert %{plan: %{user_id: nil, name: "Starter Six-Count"}} = facts.selection
    refute facts.selection.recommendation_id == selection.recommendation_id
    assert {:start, _} = Home.state(facts)
  end

  test "eligible owner facts and results exclude another user's recommendation, selection, session, and history" do
    owner = user_fixture()
    other = user_fixture()
    _owner_plan = plan_fixture(owner)
    owner_history = completed_session(owner, @monday)
    other_plan = plan_fixture(other)
    other_history = completed_session(other, DateTime.add(@now, -1, :hour))

    {:ok, other_selection} =
      Workouts.ensure_home_selection(
        Scope.for_user(other),
        slot(other, DateTime.utc_now(:second))
      )

    {:ok, other_selected} =
      Workouts.select_home_workout(Scope.for_user(other), other_selection, other_plan.id)

    assert other_selected.plan.id == other_plan.id

    assert %CoachRecommendation{user_id: other_id, home_workout_plan_id: other_plan_id} =
             Repo.get!(CoachRecommendation, other_selected.recommendation_id)

    assert other_id == other.id
    assert other_plan_id == other_plan.id

    {:ok, other_started} =
      Workouts.start_home_workout(Scope.for_user(other), other_selected, Ecto.UUID.generate())

    assert {:ok, facts} = Home.facts(Scope.for_user(owner), @now)

    assert %{recommendation_id: recommendation_id, plan: %{id: plan_id} = selected_plan} =
             facts.selection

    assert %CoachRecommendation{user_id: owner_id, home_workout_plan_id: owner_plan_id} =
             Repo.get!(CoachRecommendation, recommendation_id)

    assert owner_id == owner.id
    assert owner_plan_id == plan_id

    assert selected_plan.user_id == owner.id or
             (is_nil(selected_plan.user_id) and selected_plan.origin == :built_in)

    refute plan_id == other_plan.id
    refute recommendation_id == other_selected.recommendation_id
    refute facts.started_session && facts.started_session.id == other_started.id
    assert facts.results.today == []
    assert Enum.map(facts.results.week, & &1.id) == [owner_history.id]
    refute other_history.id in Enum.map(facts.results.week, & &1.id)
    refute other_started.id in Enum.map(facts.results.week, & &1.id)
  end

  test "current selection lookup is read-only for first use without a pointer" do
    user = user_fixture()
    scope = Scope.for_user(user)
    current = slot(user, DateTime.utc_now(:second))
    before = recommendation_snapshot(user)

    assert Workouts.current_home_selection(scope, current) == nil
    assert recommendation_snapshot(user) == before
    assert Workouts.current_started_session(scope) == nil
  end

  test "a first-use user starts on the starter for the slot" do
    user = user_fixture()

    assert recommendation_snapshot(user) == []
    assert {:ok, facts} = Home.facts(Scope.for_user(user), DateTime.utc_now(:second))
    assert {:start, %{plan: %{name: "Starter Six-Count", origin: :built_in}}} = Home.state(facts)
    assert [{_id, _fallback, _starter, nil, 1}] = recommendation_snapshot(user)
  end

  test "started, done-today, and week-complete guards preserve an existing recommendation" do
    for guard <- [:started, :done_today, :week_complete] do
      user = user_fixture()
      _plan = plan_fixture(user)

      {:ok, selection} =
        Workouts.ensure_home_selection(
          Scope.for_user(user),
          slot(user, DateTime.utc_now(:second))
        )

      before = recommendation_snapshot(user)

      facts =
        case guard do
          :started ->
            {:ok, started} =
              Workouts.start_home_workout(Scope.for_user(user), selection, Ecto.UUID.generate())

            started_id = started.id
            assert {:ok, facts} = Home.facts(Scope.for_user(user), @now)
            assert {:resume, %{id: ^started_id}} = Home.state(facts)
            facts

          :done_today ->
            completed = completed_session(user, DateTime.add(@now, -1, :hour))
            assert {:ok, facts} = Home.facts(Scope.for_user(user), @now)
            assert {:done_today, %{today: [^completed], week: [^completed]}} = Home.state(facts)
            assert facts.results == %{today: [completed], week: [completed]}
            facts

          :week_complete ->
            completed = completed_session(user, @monday, 4_800)
            assert {:ok, facts} = Home.facts(Scope.for_user(user), @now)
            assert {:week_complete, %{today: [], week: [^completed]}} = Home.state(facts)
            assert facts.results == %{today: [], week: [completed]}
            facts
        end

      assert facts.selection == nil
      assert recommendation_snapshot(user) == before
    end
  end

  test "draft and archived plans never become the Home selection" do
    user = user_fixture()
    _draft = workout_plan_draft_fixture(user)
    published = plan_fixture(user)
    {:ok, _archived} = Workouts.archive_plan(Scope.for_user(user), published.id)

    assert %WorkoutPlan{user_id: nil, origin: :built_in, state: :published} =
             Repo.one!(
               from(plan in WorkoutPlan,
                 where:
                   is_nil(plan.user_id) and plan.origin == :built_in and plan.state == :published,
                 limit: 1
               )
             )

    assert {:ok, facts} = Home.facts(Scope.for_user(user), @now)
    assert %{plan: %{user_id: nil, origin: :built_in}} = facts.selection
    assert {:start, _} = Home.state(facts)
    assert [{_, _, _, _, _}] = recommendation_snapshot(user)
  end

  test "missing built-in fallback leaves an eligible user in choose without writing a recommendation" do
    user = user_fixture()
    _history = completed_session(user, @monday)

    from(plan in WorkoutPlan,
      where: is_nil(plan.user_id) and plan.origin == :built_in and plan.state == :published
    )
    |> Repo.all()
    |> Enum.each(fn plan ->
      plan
      |> WorkoutPlan.archive_changeset(@now)
      |> Repo.update!()
    end)

    assert {:ok, facts} = Home.facts(Scope.for_user(user), @now)
    assert facts.selection == nil
    assert :choose = Home.state(facts)
    assert recommendation_snapshot(user) == []
  end

  test "an invalid timezone is returned as a Home error" do
    user = %{user_fixture() | timezone: "Invalid/Zone"}

    assert {:error, :invalid_timezone} =
             Home.facts(Scope.for_user(user), DateTime.utc_now(:second))
  end

  defp completed_session(user, completed_at, duration_sec \\ 100) do
    free_form_session_fixture(user, %{
      completed_at: completed_at,
      duration_sec_actual: duration_sec,
      burpee_count_actual: 30
    })
  end

  defp recommendation_snapshot(user) do
    Repo.all(
      from(recommendation in CoachRecommendation,
        where: recommendation.user_id == ^user.id,
        order_by: [asc: recommendation.id],
        select: {
          recommendation.id,
          recommendation.selected_workout_plan_id,
          recommendation.home_workout_plan_id,
          recommendation.pending_draft_id,
          recommendation.home_revision
        }
      )
    )
  end

  defp slot(user, now) do
    {:ok, slot} = BurpeeTrainer.Coach.Policy.required_slot(Scope.for_user(user), now)
    slot
  end
end
