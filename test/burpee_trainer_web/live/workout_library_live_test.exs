defmodule BurpeeTrainerWeb.WorkoutLibraryLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders published and draft lifecycle actions with natural-language forms", %{
    conn: conn,
    user: user
  } do
    published = plan_fixture(user, %{"name" => "Steady twenty"})
    draft = workout_plan_draft_fixture(user, %{"name" => "Quiet draft"})
    archived = plan_fixture(user, %{"name" => "Archived workout"})
    assert {:ok, _archived} = Workouts.archive_plan(user, archived.id)

    {:ok, view, _html} = live(conn, ~p"/workouts")

    assert has_element?(view, "#workout-library-page")
    assert has_element?(view, "#workout-create-form")
    assert has_element?(view, "textarea#workout-create-request")
    refute has_element?(view, "#workout-create-form select")
    refute has_element?(view, "#workout-create-form input[type='number']")
    refute has_element?(view, "[data-workout-builder]")

    assert has_element?(view, "#published-workouts[phx-update='stream']")
    assert has_element?(view, "#published-workout-#{published.id}")
    assert has_element?(view, "#start-workout-#{published.id}")
    assert has_element?(view, "#copy-workout-#{published.id}")
    assert has_element?(view, "#archive-workout-#{published.id}")

    assert has_element?(view, "#draft-workouts[phx-update='stream']")
    assert has_element?(view, "#draft-workout-#{draft.id}")
    assert has_element?(view, "#refine-workout-#{draft.id}")
    assert has_element?(view, "#publish-workout-#{draft.id}")
    assert has_element?(view, "#delete-draft-#{draft.id}")

    refute has_element?(view, "#published-workout-#{archived.id}")
    refute has_element?(view, "#draft-workout-#{archived.id}")
  end

  test "authenticated navigation exposes Home, Library, Videos, and History", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workouts")

    for id <- ~w[desktop-home-nav desktop-library-nav desktop-videos-nav desktop-history-nav] do
      assert has_element?(view, "##{id}")
    end

    for id <- ~w[mobile-home-nav mobile-library-nav mobile-videos-nav mobile-history-nav] do
      assert has_element?(view, "##{id}")
    end
  end

  test "copy, publish, archive, and delete re-stream lifecycle results", %{conn: conn, user: user} do
    published = plan_fixture(user, %{"name" => "Lifecycle source"})
    deletable = workout_plan_draft_fixture(user, %{"name" => "Delete me"})
    {:ok, view, _html} = live(conn, ~p"/workouts")

    view |> element("#copy-workout-#{published.id}") |> render_click()
    [copied] = Enum.filter(Workouts.list_drafts(user), &(&1.id != deletable.id))
    assert has_element?(view, "#draft-workout-#{copied.id}")

    view |> element("#publish-workout-#{copied.id}") |> render_click()
    assert has_element?(view, "#published-workout-#{copied.id}")
    refute has_element?(view, "#draft-workout-#{copied.id}")

    view |> element("#archive-workout-#{copied.id}") |> render_click()
    refute has_element?(view, "#published-workout-#{copied.id}")
    assert Repo.get!(WorkoutPlan, copied.id).state == :archived

    view |> element("#delete-draft-#{deletable.id}") |> render_click()
    refute has_element?(view, "#draft-workout-#{deletable.id}")
    assert is_nil(Repo.get(WorkoutPlan, deletable.id))
  end

  test "Start reuses the rendered token for duplicate delivery and rejects a forged token", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{"name" => "Replay-safe start"})
    {:ok, view, _html} = live(conn, ~p"/workouts")

    [client_session_id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#start-workout-#{plan.id}")
      |> LazyHTML.attribute("phx-value-client-session-id")

    params = %{
      "id" => Integer.to_string(plan.id),
      "client-session-id" => client_session_id
    }

    render_click(view, "start", Map.put(params, "client-session-id", Ecto.UUID.generate()))
    assert Repo.aggregate(WorkoutSession, :count) == 0

    render_click(view, "start", params)

    [session] = Repo.all(WorkoutSession)
    assert {:ok, replayed} = Workouts.start_plan(user, plan.id, client_session_id)
    assert replayed.id == session.id
    assert Repo.aggregate(WorkoutSession, :count) == 1
    assert session.client_session_id == client_session_id
    assert_redirect(view, ~p"/session/#{session.id}")
  end

  test "Start creates exactly one immutable session before navigating by session id", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{"name" => "Exact start"})
    {:ok, view, _html} = live(conn, ~p"/workouts")

    view |> element("#start-workout-#{plan.id}") |> render_click()

    session = Workouts.current_started_session(user)
    assert session.plan_id == plan.id
    assert session.display_name_snapshot == "Exact start"
    assert_redirect(view, ~p"/session/#{session.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end
end
