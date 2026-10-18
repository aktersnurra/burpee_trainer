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

  test "returning user without a completed session sees the starter, not the placeholder", %{
    conn: _conn
  } do
    user = returning_user()
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)

    {:ok, pinned} =
      Workouts.ensure_recommendation(Scope.for_user(user), %{
        slot_key: slot.slot_key,
        slot_date: slot.slot_date
      })

    socket = mounted_socket(user, now)

    assert socket.assigns.home_selection.recommendation_id == pinned.id
    assert socket.assigns.home_selection.plan.name == "Starter Six-Count"
    refute_received :unexpected_provider
  end

  test "returning user mount preserves owned draft content without a provider call", %{
    conn: _conn
  } do
    user = returning_user()
    draft = workout_plan_draft_fixture(user, %{name: "Keep draft"})

    assert_returning_mount_preserves_plan(user, draft, :draft)
  end

  test "returning user mount preserves owned published content without a provider call", %{
    conn: _conn
  } do
    user = returning_user()
    published = plan_fixture(user, %{name: "Keep published"})

    assert_returning_mount_preserves_plan(user, published, :published)
  end

  test "returning user mount preserves owned archived content without a provider call", %{
    conn: _conn
  } do
    user = returning_user()
    draft = workout_plan_draft_fixture(user, %{name: "Keep archived"})

    archived =
      draft
      |> WorkoutPlan.publish_changeset(DateTime.utc_now(:second))
      |> Repo.update!()
      |> WorkoutPlan.archive_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

    assert_returning_mount_preserves_plan(user, archived, :archived)
  end

  test "returning user mount keeps historical-only recommendation on the existing path", %{
    conn: _conn
  } do
    user = returning_user()
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)

    {:ok, historical} =
      Workouts.ensure_recommendation(Scope.for_user(user), %{
        slot_key: "historical:" <> slot.slot_key,
        slot_date: Date.add(slot.slot_date, -7)
      })

    socket = mounted_socket(user, now)

    assert Date.compare(Repo.get!(CoachRecommendation, historical.id).slot_date, slot.slot_date) ==
             :lt

    assert socket.assigns.home_selection != nil
    refute_received :unexpected_provider
  end

  test "returning user mount keeps historical-only manual session on the existing path", %{
    conn: _conn
  } do
    user = returning_user()
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)
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

    socket = mounted_socket(user, now)

    assert Repo.get!(WorkoutSession, session.id).completed_at == completed_at
    assert Date.compare(DateTime.to_date(completed_at), slot.slot_date) == :lt
    assert socket.assigns.home_selection != nil
    refute_received :unexpected_provider
  end

  test "returning user mount keeps historical-only built-in session on the existing path", %{
    conn: _conn
  } do
    user = returning_user()
    built_in = Enum.find(Workouts.list_library(Scope.for_user(user)), &(&1.origin == :built_in))
    session = session_from_plan_fixture(user, built_in)
    completed_at = session.completed_at
    now = DateTime.add(completed_at, 86_400, :second)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)

    assert_historical_session_mount(user, now, slot, session, :plan, completed_at)
  end

  test "returning user mount keeps historical-only video session on the existing path", %{
    conn: _conn
  } do
    user = returning_user()
    video = video_fixture(%{burpee_count: 60})
    {:ok, started} = Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    {:ok, session} =
      Workouts.complete_session(
        Scope.for_user(user),
        started.id,
        %{"burpee_count_actual" => 25, "duration_sec_actual" => 120},
        :timed
      )

    completed_at = session.completed_at
    now = DateTime.add(completed_at, 86_400, :second)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)

    assert_historical_session_mount(user, now, slot, session, :video, completed_at)
  end

  test "without a selection, Start, adjustment submit and adjustment change are inert", %{
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
          {"submit_home_action",
           %{"client_session_id" => token, "home_adjustment" => %{"instruction" => ""}}},
          {"submit_home_action",
           %{
             "client_session_id" => token,
             "home_adjustment" => %{"instruction" => "Make it harder"}
           }},
          {"change_adjustment", %{"home_adjustment" => %{"instruction" => "Make it harder"}}}
        ] do
      assert {:noreply, ^socket} = HomeLive.handle_event(event, params, socket)
    end

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    refute_received :unexpected_provider
  end

  defp assert_historical_session_mount(user, now, slot, session, source_kind, completed_at) do
    assert Repo.aggregate(from(plan in WorkoutPlan, where: plan.user_id == ^user.id), :count) == 0

    assert Repo.aggregate(
             from(recommendation in CoachRecommendation,
               where: recommendation.user_id == ^user.id
             ),
             :count
           ) == 0

    socket = mounted_socket(user, now)

    assert %WorkoutSession{source_kind: ^source_kind, completed_at: ^completed_at} =
             Repo.get!(WorkoutSession, session.id)

    assert Date.compare(DateTime.to_date(completed_at), slot.slot_date) == :lt
    assert socket.assigns.home_selection != nil
    refute_received :unexpected_provider
  end

  defp returning_user do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    user
  end

  defp assert_returning_mount_preserves_plan(user, plan, state) do
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
