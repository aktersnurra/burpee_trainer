defmodule BurpeeTrainerWeb.HomeReturningMountTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, ReqStub, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession}
  alias BurpeeTrainerWeb.HomeLive

  setup do
    previous_req = Req.default_options()
    parent = self()
    ReqStub.default(fn _request -> send(parent, :unexpected_provider) end)
    on_exit(fn -> Req.default_options(previous_req) end)
    :ok
  end

  test "returning user mount preserves owned draft, published and archived content without a provider call" do
    for {state, build} <- [
          draft: &workout_plan_draft_fixture(&1, %{name: "Keep draft"}),
          published: &plan_fixture(&1, %{name: "Keep published"}),
          archived: &archived_plan/1
        ] do
      user = returning_user()
      plan = build.(user)
      now = DateTime.utc_now(:second)
      before = Repo.get!(WorkoutPlan, plan.id)
      socket = mounted_socket(user, now)
      after_mount = Repo.get!(WorkoutPlan, plan.id)

      assert after_mount.state == state
      assert after_mount.name == before.name
      assert after_mount.definition_json == before.definition_json
      assert socket.assigns.home_selection != nil
      refute_received :unexpected_provider
    end
  end

  test "returning user mount keeps historical-only rows on the existing path" do
    for {label, build} <- [
          recommendation: &historical_recommendation/1,
          manual_session: &historical_manual_session/1,
          built_in_session: &historical_plan_session/1,
          video_session: &historical_video_session/1
        ] do
      user = returning_user()
      {now, reload_date} = build.(user)
      {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)

      socket = mounted_socket(user, now)

      assert Date.compare(reload_date.(), slot.slot_date) == :lt, "#{label}"
      assert socket.assigns.home_selection != nil
      refute_received :unexpected_provider
    end
  end

  test "without a selection, Start, Edit and New are inert", %{
    conn: _conn
  } do
    user = returning_user()
    now = DateTime.utc_now(:second)

    from(plan in WorkoutPlan, where: is_nil(plan.user_id) and plan.state == :published)
    |> Repo.all()
    |> Enum.each(&(&1 |> WorkoutPlan.archive_changeset(now) |> Repo.update!()))

    socket = mounted_socket(user, now)
    assert socket.assigns.home_state == :choose
    assert socket.assigns.home_selection == nil
    token = socket.assigns.start_client_session_id

    for {event, params} <- [
          {"start_workout", %{"client_session_id" => token}},
          {"edit_current_workout", %{}},
          {"new_workout", %{}}
        ] do
      assert {:noreply, ^socket} = HomeLive.handle_event(event, params, socket)
    end

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    refute_received :unexpected_provider
  end

  defp archived_plan(user) do
    user
    |> workout_plan_draft_fixture(%{name: "Keep archived"})
    |> WorkoutPlan.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
    |> WorkoutPlan.archive_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp historical_recommendation(user) do
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)

    {:ok, historical} =
      Workouts.ensure_recommendation(Scope.for_user(user), %{
        slot_key: "historical:" <> slot.slot_key,
        slot_date: Date.add(slot.slot_date, -7)
      })

    {now, fn -> Repo.get!(CoachRecommendation, historical.id).slot_date end}
  end

  defp historical_manual_session(user) do
    now = DateTime.utc_now(:second)
    completed_at = DateTime.add(now, -86_400, :second)

    session =
      Repo.insert!(%WorkoutSession{
        user_id: user.id,
        state: :completed,
        source_kind: :manual,
        capture_mode: :logged,
        burpee_type: :six_count,
        completed_at: completed_at,
        burpee_count_actual: 25,
        duration_sec_actual: 120
      })

    {now, reloaded_session_date(session, :manual)}
  end

  defp historical_plan_session(user) do
    built_in = Enum.find(Workouts.list_library(Scope.for_user(user)), &(&1.origin == :built_in))
    historical_owned_session(user, session_from_plan_fixture(user, built_in), :plan)
  end

  defp historical_video_session(user) do
    video = video_fixture(%{burpee_count: 60})
    {:ok, started} = Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    {:ok, session} =
      Workouts.complete_session(
        Scope.for_user(user),
        started.id,
        %{"burpee_count_actual" => 25, "duration_sec_actual" => 120},
        :timed
      )

    historical_owned_session(user, session, :video)
  end

  defp historical_owned_session(user, session, source_kind) do
    assert Repo.aggregate(from(plan in WorkoutPlan, where: plan.user_id == ^user.id), :count) == 0

    assert Repo.aggregate(
             from(recommendation in CoachRecommendation,
               where: recommendation.user_id == ^user.id
             ),
             :count
           ) == 0

    {DateTime.add(session.completed_at, 86_400, :second),
     reloaded_session_date(session, source_kind)}
  end

  defp reloaded_session_date(session, source_kind) do
    completed_at = session.completed_at

    fn ->
      assert %WorkoutSession{source_kind: ^source_kind, completed_at: ^completed_at} =
               Repo.get!(WorkoutSession, session.id)

      DateTime.to_date(completed_at)
    end
  end

  defp returning_user do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    user
  end

  defp mounted_socket(user, now) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: BurpeeTrainerWeb.Endpoint,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        current_scope: BurpeeTrainer.Accounts.Scope.for_user(user),
        current_level: :level_1a,
        flash: %{},
        home_now: fn -> now end
      }
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    socket
  end
end
