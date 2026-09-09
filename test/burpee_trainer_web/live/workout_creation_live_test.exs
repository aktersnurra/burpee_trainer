defmodule BurpeeTrainerWeb.WorkoutCreationLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "configuration is composed, adjustable and has no preview", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/workouts/new")
    assert has_element?(view, "#creation-close[href='/workouts']")
    assert has_element?(view, "#creation-duration[value='20:00']")
    assert has_element?(view, "#creation-reps[value='120']")
    assert has_element?(view, "#choice-burpee_type-six_count[aria-pressed='true']")
    refute has_element?(view, "#draft-timeline")
    refute has_element?(view, "#desktop-home-nav")
    view |> element("#duration-increase") |> render_click()
    assert has_element?(view, "#creation-duration[value='21:00']")
    view |> element("#choice-burpee_type-navy_seal") |> render_click()
    assert has_element?(view, "#choice-burpee_type-navy_seal[aria-pressed='true']")
    view |> element("#creation-note") |> render_click()
    assert has_element?(view, "#creation-editor[role='dialog']")

    view
    |> form("#creation-editor-form", editor: %{text: "More recovery through the middle"})
    |> render_submit()

    assert has_element?(view, "#creation-note", "More recovery through the middle")
    refute has_element?(view, "#creation-editor")
  end

  test "invalid numbers and disabled provider never persist a draft", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/workouts/new")

    view
    |> form("#creation-form", creation_parameters: %{duration: "oops", reps: "0"})
    |> render_submit()

    assert has_element?(view, "#creation-error")
    assert Workouts.list_drafts(user) == []

    view
    |> form("#creation-form", creation_parameters: %{duration: "20:00", reps: "120"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#creation-error")
    assert Workouts.list_drafts(user) == []
  end

  test "draft summary returns to configuration and Start publishes before exact session navigation",
       %{conn: conn, user: user} do
    draft = workout_plan_draft_fixture(user)
    {:ok, view, _} = live(conn, ~p"/workouts/drafts/#{draft.id}")
    assert has_element?(view, "#draft-timeline")
    assert has_element?(view, "#draft-summary")
    refute has_element?(view, "#draft-edit")
    view |> element("#draft-summary") |> render_click()
    assert has_element?(view, "#creation-form")
    refute has_element?(view, "#draft-timeline")
    {:ok, view, _} = live(conn, ~p"/workouts/drafts/#{draft.id}")
    view |> element("#draft-start") |> render_click()
    assert Repo.get!(WorkoutPlan, draft.id).state == :published
    session = Workouts.current_started_session(user)
    assert session.plan_id == draft.id
    assert session.program_snapshot == draft.program_json
    assert_redirect(view, ~p"/session/#{session.id}")
  end

  test "another user's draft cannot be opened", %{conn: conn} do
    draft = workout_plan_draft_fixture(user_fixture())

    assert {:error, {:live_redirect, %{to: "/workouts"}}} =
             live(conn, ~p"/workouts/drafts/#{draft.id}")
  end
end
