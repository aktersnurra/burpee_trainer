defmodule BurpeeTrainerWeb.HistorySnapshotTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "History renders completed tombstones from immutable snapshots and completed_at", %{
    conn: conn,
    user: user
  } do
    session =
      insert_history(user, %{
        source_kind: :plan,
        display_name_snapshot: "Legacy ladder snapshot",
        workout_type_snapshot: :six_count,
        program_snapshot: nil,
        content_hash: nil,
        burpee_type: :six_count,
        burpee_count_planned: 40,
        duration_sec_planned: 1_200,
        burpee_count_actual: 38,
        duration_sec_actual: 1_180,
        prescribed_sets_completed: 4,
        reps_delta: -2,
        shortened: true,
        recovery_delta_sec: 7,
        pace_delta_sec: 1.25,
        cadence_decline: 0.15,
        completed_at: ~U[2025-01-02 03:04:05Z]
      })

    {:ok, view, _html} = live(conn, ~p"/progress")
    view |> element("#home-history-period-all") |> render_click()

    assert has_element?(
             view,
             "#home-history-inspect-#{session.id} .home-history-session-name",
             "Legacy ladder snapshot"
           )

    view |> element("#home-history-inspect-#{session.id}") |> render_click()
    assert has_element?(view, "#home-history-sheet", "Jan 2, 2025")
    assert has_element?(view, "#home-history-sheet-details-#{session.id} [data-actual-reps='38']")
    assert has_element?(view, "#home-history-sheet-details-#{session.id}", "Reps · 40")

    [persisted] = Workouts.list_sessions(BurpeeTrainer.Accounts.Scope.for_user(user))
    assert persisted.completed_at == ~U[2025-01-02 03:04:05Z]
    assert persisted.display_name_snapshot == "Legacy ladder snapshot"
    assert is_nil(persisted.program_snapshot)
  end

  test "nil-count video history shows confirmed actual reps exactly as persisted", %{
    conn: conn,
    user: user
  } do
    session =
      insert_history(user, %{
        source_kind: :video,
        display_name_snapshot: "Uncounted follow-along",
        workout_type_snapshot: :navy_seal,
        video_snapshot: %{
          "name" => "Uncounted follow-along",
          "filename" => "uncounted.mp4",
          "type" => "navy_seal",
          "duration" => 900,
          "count" => nil,
          "format" => "follow_along"
        },
        content_hash: String.duplicate("b", 64),
        burpee_type: :navy_seal,
        burpee_count_planned: nil,
        duration_sec_planned: 900,
        burpee_count_actual: 27,
        duration_sec_actual: 912,
        completed_at: ~U[2025-02-03 04:05:06Z]
      })

    {:ok, view, _html} = live(conn, ~p"/progress")
    view |> element("#home-history-period-all") |> render_click()

    assert has_element?(
             view,
             "#home-history-inspect-#{session.id} .home-history-session-name",
             "Uncounted follow-along"
           )

    view |> element("#home-history-inspect-#{session.id}") |> render_click()
    assert has_element?(view, "#home-history-sheet-details-#{session.id} [data-actual-reps='27']")
    assert has_element?(view, "#home-history-sheet-details-#{session.id}", "Reps · —")

    persisted = Repo.get!(WorkoutSession, session.id)
    assert persisted.video_snapshot["count"] == nil
    assert persisted.burpee_count_planned == nil
    assert persisted.burpee_count_actual == 27
  end

  defp insert_history(user, attrs) do
    attrs =
      Map.merge(
        %{
          user_id: user.id,
          state: :completed,
          capture_mode: :logged,
          context_low_energy: false,
          context_high_energy: false,
          context_heat_affected: false
        },
        attrs
      )

    %WorkoutSession{}
    |> struct!(attrs)
    |> Repo.insert!()
  end
end
