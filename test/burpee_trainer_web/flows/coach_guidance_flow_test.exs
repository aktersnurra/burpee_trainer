defmodule BurpeeTrainerWeb.Flows.CoachGuidanceFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Coach.{Guidance, Memory}
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "completed Home keeps Coach behind its icon; saved guidance survives reload and removal",
       %{conn: conn, user: user} do
    complete_history(user, DateTime.utc_now(:second), 120)
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#home-coach-guidance-form")
    view |> element("#home-result-coach") |> render_click()

    view
    |> form("#home-coach-guidance-form", coach_guidance: %{text: "  Build toward 50 reps  "})
    |> render_submit()

    assert has_element?(view, "#home-coach-guidance-status[role=status]", "Saved for your coach")
    assert [%{text: "Build toward 50 reps"} = entry] = Guidance.list(user)
    {:ok, reopened, _} = live(conn, ~p"/")
    refute has_element?(reopened, "#home-coach-guidance-form")
    reopened |> element("#home-result-coach") |> render_click()
    assert has_element?(reopened, "#home-coach-summary", entry.text)
    assert has_element?(reopened, "#history-coach-memory:not([open])")
    refute has_element?(reopened, ".coach-guidance-description, .history-coach-summary")
    assert has_element?(reopened, "#history-coach-entry-#{entry.id}", entry.text)
    reopened |> element("#history-coach-memory-toggle") |> render_click()
    reopened |> element("#history-coach-edit-#{entry.id}") |> render_click()
    assert has_element?(reopened, "#history-coach-memory[open]")

    reopened
    |> form("#history-coach-edit-form-#{entry.id}", coach_memory: %{text: "Build toward 60 reps"})
    |> render_submit()

    assert has_element?(reopened, "#home-coach-summary", "Build toward 60 reps")
    assert has_element?(reopened, "#history-coach-memory[open]")
    assert [%{text: "Build toward 60 reps"}] = Guidance.list(user)
    {:ok, reopened, _} = live(conn, ~p"/?history=1")
    reopened |> element("#history-coach-open") |> render_click()
    assert has_element?(reopened, "#home-coach-summary", "Build toward 60 reps")
    reopened |> element("#history-coach-remove-#{entry.id}") |> render_click()
    refute has_element?(reopened, "#home-coach-summary", "Build toward 60 reps")
    refute has_element?(reopened, "#history-coach-entry-#{entry.id}")
    assert Guidance.list(user) == []
    reopened |> element("#home-coach-back") |> render_click()
    assert has_element?(reopened, "#home-history")
    reopened |> element("#home-history-toggle") |> render_click()
    assert has_element?(reopened, "#home-done-today")
  end

  test "late classification cannot overwrite an edit", _context do
    user = user_fixture()
    {:ok, entry} = Guidance.add(user, "Build toward 50 reps")

    assert {:error, :stale_review} =
             Guidance.review(entry.id,
               complete: fn _, _ ->
                 assert {:ok, _} = Guidance.update(user, entry.id, "Build toward 60 reps")
                 {:ok, %{"kind" => "lasting", "summary" => "old"}}
               end
             )

    assert [%{text: "Build toward 60 reps", kind: "pending", summary: nil}] = Guidance.list(user)
    assert [%{text: "Build toward 60 reps"}] = Memory.global_context(user).coach_guidance.pending
  end

  defp complete_history(user, completed_at, duration_sec, attrs \\ []) do
    %WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      display_name_snapshot: "Historical workout",
      workout_type_snapshot: :six_count,
      burpee_type: :six_count,
      burpee_count_actual: 20,
      duration_sec_actual: duration_sec,
      completed_at: completed_at,
      capture_mode: :logged
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end
end
