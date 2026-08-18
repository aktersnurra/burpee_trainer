defmodule BurpeeTrainerWeb.SessionAnalysisLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "redirects away from a tracked session that is still started", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    assert {:ok, session} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

    assert {:error, {:live_redirect, %{to: "/stats"}}} =
             live(conn, ~p"/stats/sessions/#{session.id}")
  end

  test "redirects a missing session id without raising", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/stats"}}} =
             live(conn, ~p"/stats/sessions/999999999")
  end

  test "redirects a foreign completed tracked session without raising", %{conn: conn} do
    foreign_user = user_fixture()
    foreign_session = completed_tracked_session(foreign_user)

    assert {:error, {:live_redirect, %{to: "/stats"}}} =
             live(conn, ~p"/stats/sessions/#{foreign_session.id}")
  end

  test "renders completed tracked analysis from immutable session facts", %{
    conn: conn,
    user: user
  } do
    session = completed_tracked_session(user)

    assert {:ok, view, _html} = live(conn, ~p"/stats/sessions/#{session.id}")

    assert has_element?(
             view,
             "#session-analysis-page[data-session-id='#{session.id}'][data-display-name='Snapshot intervals'][data-prescribed-sets-completed='1'][data-reps-delta='-1'][data-shortened][data-recovery-delta-sec='2'][data-pace-delta-sec='0.5'][data-cadence-decline='0.1']"
           )

    assert has_element?(view, "#session-analysis-name", "Snapshot intervals")
    assert has_element?(view, "#session-analysis-date", "4 Mar 2025")
    assert has_element?(view, "#session-analysis-actual-reps", "3")
  end

  defp completed_tracked_session(user) do
    %WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :plan,
      display_name_snapshot: "Snapshot intervals",
      workout_type_snapshot: :six_count,
      program_snapshot: nil,
      burpee_type: :six_count,
      burpee_count_planned: 4,
      duration_sec_planned: 20,
      burpee_count_actual: 3,
      duration_sec_actual: 15,
      completed_at: ~U[2025-03-04 05:06:07Z],
      capture_mode: :tracked,
      cadence_ms: "[0,5000,10000,15000]",
      target_pace_sec: 5.0,
      pace_consistency: 1.0,
      prescribed_sets_completed: 1,
      reps_delta: -1,
      shortened: true,
      recovery_delta_sec: 2,
      pace_delta_sec: 0.5,
      cadence_decline: 0.1
    }
    |> Repo.insert!()
  end
end
