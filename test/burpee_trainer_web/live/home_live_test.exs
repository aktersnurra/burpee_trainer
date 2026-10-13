defmodule BurpeeTrainerWeb.HomeLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Notebook, Policy}
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}
  alias BurpeeTrainerWeb.HomeLive

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "Coach is a separate view and an unsent message survives switching to Analytics", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/")

    refute has_element?(
             view,
             "#home-coach-message-form, #home-coach-toggle, .home-view-nav, #home-result-coach"
           )

    render_click(view, "open_coach", %{})
    refute has_element?(view, "#home-coach-panel")
    pid = view.pid
    view = history_route(conn, view)
    assert has_element?(view, "#home-history-empty")
    refute has_element?(view, "#history-coach-area, #home-coach-message-form")
    render_patch(view, ~p"/coach")
    assert view.pid == pid
    assert has_element?(view, "#home-history #home-coach-panel")

    view
    |> form("#home-coach-message-form", coach_message: %{text: "Build toward 50 reps"})
    |> render_change()

    view |> element("#history-coach-summary") |> render_click()
    assert_patch(view, "/progress")
    assert has_element?(view, "#home-history")
    refute has_element?(view, "#home-coach-panel")
    render_patch(view, ~p"/coach")
    assert has_element?(view, "#home-coach-message-text", "Build toward 50 reps")
    assert Notebook.get(Scope.for_user(user)).body == ""
    view |> element("#history-coach-summary") |> render_click()
    assert_patch(view, "/progress")
    view = home_route(conn, view)
    assert view.pid == pid
    assert has_element?(view, "#home-state-content:not([hidden]):not([inert])")
    refute has_element?(view, "#home-coach-panel")
  end

  test "invalid guidance remains editable and can be corrected and saved", %{
    conn: conn,
    user: user
  } do
    {:ok, history, _} = live(conn, ~p"/progress")
    render_patch(history, ~p"/coach")
    view = history
    view |> form("#home-coach-message-form", coach_message: %{text: "  "}) |> render_submit()
    assert has_element?(view, "#home-coach-status[role=status]", "Enter a message")
    assert Notebook.get(Scope.for_user(user)).body == ""
    long_text = String.duplicate("x", 1001)

    view
    |> form("#home-coach-message-form", coach_message: %{text: long_text})
    |> render_submit()

    assert has_element?(view, "#home-coach-message-text", long_text)
    assert Notebook.get(Scope.for_user(user)).body == ""

    view
    |> form("#home-coach-message-form", coach_message: %{text: "Keep sets shorter"})
    |> render_submit()

    render_async(view)
    assert Notebook.get(Scope.for_user(user)).body == ""
    assert has_element?(view, "#home-coach-reply[role=status]", "Coach unavailable")
  end

  test "empty History opens from weekly progress without showing a dashboard", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-week-track")
    assert has_element?(view, "#home-history-toggle[href='/progress']")

    view = history_route(conn, view)
    assert has_element?(view, "#home-history-empty")
    refute has_element?(view, "#home-history-status, #home-history-weekly")
    refute has_element?(view, "#home-history-period-twelve_weeks, .home-history-sessions-heading")

    # The week's progress stays on top; on History it is the way back Home.
    assert has_element?(view, "#history-progress #home-week-track")
    assert has_element?(view, "#history-progress #home-history-close[aria-label='Back to Home']")
    refute has_element?(view, "#home-state-content")
    view = home_route(conn, view)

    assert has_element?(
             view,
             "#home-history-toggle[href='/progress'][aria-label='Open Progress']"
           )

    assert {:error, {:live_redirect, %{to: "/progress"}}} = live(conn, ~p"/?history=1")
    {:ok, linked_view, _} = live(conn, ~p"/progress")
    assert has_element?(linked_view, "#home-history-empty")
  end

  test "History is presentation only and restores the working adjustment", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    complete_history(user, DateTime.add(DateTime.utc_now(:second), -90 * 86400), 1200)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()

    view |> element("#home-new-workout") |> render_click()
    view |> form("#home-new-form", home_workout: %{note: "20 sets of 6"}) |> render_change()

    {:ok, before} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    pid = view.pid
    view = history_route(conn, view)
    assert has_element?(view, "#home-history")
    assert has_element?(view, "#home-history-empty")
    refute has_element?(view, "#home-state-content")
    assert has_element?(view, "#history-progress #home-history-close[aria-label='Back to Home']")

    view = home_route(conn, view)
    assert view.pid == pid
    refute has_element?(view, "#home-history")
    assert has_element?(view, "#home-expansion[data-open=true]")
    assert has_element?(view, "#home-new-form")
    assert :sys.get_state(view.pid).socket.assigns.workout_form[:note].value == "20 sets of 6"

    assert {:ok, ^before} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "Home renders one recommendation-first action without legacy authoring surfaces", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-ready-recommendation")
    assert has_element?(view, "#home-action")
    refute has_element?(view, "#home-adjustment-form")
    assert has_element?(view, "#home-action[aria-label='Start workout']", "Start")
    assert has_element?(view, "#home-new-workout[inert]")
    refute has_element?(view, "#resume-recommended-workout")
    refute has_element?(view, "#tell-coach-button")
    refute has_element?(view, "#manual-workout-form")
    assert recommendation.selected_workout_plan_id
  end

  test "Home replaces malformed pinned events before rendering inspection", %{
    conn: conn,
    user: user
  } do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    plan = workout_plan_draft_fixture(user)

    Repo.get!(BurpeeTrainer.Workouts.CoachRecommendation, shown.recommendation_id)
    |> Ecto.Changeset.change(pending_draft_id: plan.id)
    |> Repo.update!()

    {:ok, pinned} = Workouts.select_home_workout(Scope.for_user(user), shown, plan.id)

    corrupt =
      plan
      |> Ecto.Changeset.change(
        definition_json: Map.put(plan.definition_json, "events", ["malformed"])
      )
      |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-ready-recommendation")
    assert has_element?(view, "#home-action")
    assert {:ok, fallback} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    assert fallback.plan.origin == :built_in
    assert fallback.home_revision == pinned.home_revision + 1
    assert Repo.reload!(corrupt) == corrupt
  end

  test "Other workouts toolbar keeps Filter adjacent to tabs and controls above results", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-alternatives-panel[hidden] #home-alternatives-toolbar")
    refute has_element?(view, "#home-other-workouts")
    view |> element("#home-title-action") |> render_click()

    assert has_element?(
             view,
             "#home-alternatives-panel:not([hidden]) #home-alternatives-toolbar > [role=tablist]"
           )

    assert has_element?(view, "#home-alternatives-toolbar > [role=tablist] + #home-filter-toggle")
    refute has_element?(view, "[role=tablist] #home-filter-toggle")
    assert has_element?(view, "#home-tab-workouts[role=tab][aria-selected=true]")
    view |> element("#home-filter-toggle") |> render_click()

    assert has_element?(
             view,
             "#home-filter-toggle[aria-expanded=true][aria-controls=home-filters]"
           )

    assert has_element?(view, "#home-alternatives-toolbar + #home-filters")
    assert has_element?(view, "#home-filters ~ #home-alternatives")
    view |> element("#home-type-six_count") |> render_click()
    view |> element("#home-tab-videos") |> render_click()

    empty_text =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-alternatives-empty")
      |> LazyHTML.text()
      |> String.trim()

    assert empty_text == "No matching videos. Try changing the filters."
    assert has_element?(view, "#home-type-six_count[aria-pressed=false]")
    view |> element("#home-filter-reset") |> render_click()
    assert has_element?(view, "#home-type-six_count[aria-pressed=true]")
    view |> element("#home-title-action") |> render_click()
    assert has_element?(view, "#home-alternatives-panel:not([hidden]) #home-filter-toggle")
  end

  test "Home filters survive the browser button's empty value metadata", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-filter-toggle") |> render_click()

    assert has_element?(view, "#home-current-level", "Level 1A is your current level.")

    assert has_element?(
             view,
             "[aria-label='Catalog level'][aria-describedby='home-current-level']"
           )

    assert has_element?(view, ".home-filter-level-heading #home-filter-reset")
    assert has_element?(view, "#home-week-track[role=progressbar][aria-valuemax='4800']")

    # LiveView's browser client adds button.value after phx-value-* metadata.
    view |> element("#home-type-six_count") |> render_click(%{"value" => ""})
    assert has_element?(view, "#home-type-six_count[aria-pressed=false]")
    assert has_element?(view, "#home-type-navy_seal[aria-pressed=true]")

    view |> element("#home-level-level_1a") |> render_click(%{"value" => ""})
    assert has_element?(view, "#home-level-level_1a[aria-pressed=false]")
    assert has_element?(view, "#home-level-level_1b[aria-pressed=true]")
    view |> element("#home-filter-reset") |> render_click()
    assert has_element?(view, "#home-type-six_count[aria-pressed=true]")
    assert has_element?(view, "#home-level-level_1a[aria-pressed=true]")
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "alternative rows carry real plan and video metadata without changing direct selection", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)
    plan = Repo.get!(BurpeeTrainer.Workouts.WorkoutPlan, recommendation.selected_workout_plan_id)
    video = video_fixture(%{duration_sec: 1200, burpee_count: 60})
    unknown = video_fixture()
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-filter-toggle") |> render_click()

    for level <- BurpeeTrainer.Levels.all_levels() do
      selector = "#home-level-#{level}[aria-pressed=false]"
      if has_element?(view, selector), do: view |> element(selector) |> render_click()
    end

    assert has_element?(
             view,
             "#home-alternative-plan-#{plan.id} .home-alternative-metadata",
             "#{plan.target_reps} reps"
           )

    view |> element("#home-alternative-plan-#{plan.id}-select") |> render_click()
    assert has_element?(view, "#home-summary", plan.name)
    assert has_element?(view, "#home-alternatives-panel[hidden]")
    assert Repo.aggregate(WorkoutSession, :count) == 0
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-tab-videos") |> render_click()

    assert has_element?(
             view,
             "#home-alternative-video-#{video.id} .home-alternative-metadata",
             "20 min · 60 reps"
           )

    # Unknown-count videos still have no catalog level; metadata must not alter filter eligibility.
    refute has_element?(view, "#home-alternative-video-#{unknown.id}")
    assert has_element?(view, "#home-summary", plan.name)
    view |> element("#home-alternative-video-#{video.id}-select") |> render_click()
    session = Workouts.current_started_session(Scope.for_user(user))
    assert session.workout_video_id == video.id
    assert_redirect(view, ~p"/videos/#{video.id}/session/#{session.id}")
  end

  test "Switch appears on expansion and Start has a standalone action", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")

    assert has_element?(view, "#home-title-action[inert]")
    refute has_element?(view, "#home-title-action", "Change")
    assert has_element?(view, "#home-expansion-content[inert]")
    refute has_element?(view, "#home-other-workouts")

    [commands] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-title-action")
      |> LazyHTML.attribute("phx-click")

    assert [
             ["set_attr", %{"attr" => ["inert", ""]}],
             ["remove_attr", %{"attr" => "hidden", "to" => "#home-alternatives-panel"}],
             ["focus", %{"to" => "#home-chooser-close"}],
             ["push", %{"event" => "open_chooser"}]
           ] = Jason.decode!(commands)

    view |> element("#home-title-action") |> render_click()
    assert has_element?(view, "#home-alternatives-panel[role=dialog]:not([hidden])")
    refute has_element?(view, "#home-expansion-content[inert] #home-alternatives-panel")
    view |> element("#home-chooser-close") |> render_click()
    view |> element("#home-summary") |> render_click()

    assert has_element?(view, "#home-title-action[aria-label='Switch workout']", "Switch")
    assert has_element?(view, "#home-action[type=button][aria-label='Start workout']", "Start")
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "chooser close and selection hide the client-opened dialog before restoring Home", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-title-action") |> render_click()
    doc = render(view) |> LazyHTML.from_fragment()

    [close] = doc |> LazyHTML.query("#home-chooser-close") |> LazyHTML.attribute("phx-click")

    assert [
             ["set_attr", %{"attr" => ["hidden", ""], "to" => "#home-alternatives-panel"}],
             ["remove_attr", %{"attr" => "inert"}],
             ["focus", %{"to" => "#home-title-action"}],
             ["push", %{"event" => "close_chooser"}]
           ] = Jason.decode!(close)

    [selection | _] =
      doc
      |> LazyHTML.query("#home-alternatives .home-alternative")
      |> LazyHTML.attribute("phx-click")

    assert [
             ["set_attr", %{"attr" => ["hidden", ""], "to" => "#home-alternatives-panel"}],
             ["remove_attr", %{"attr" => "inert"}],
             ["push", %{"event" => "select_alternative"}]
           ] = Jason.decode!(selection)
  end

  test "selecting another workout tells the ignored adjustment input to clear", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    alternative = plan_fixture(user, %{name: "Another workout"})
    {:ok, view, _} = live(conn, ~p"/")

    render_click(view, "change_adjustment", %{
      "home_adjustment" => %{"instruction" => "Old instruction"}
    })

    render_click(view, "select_alternative", %{
      "kind" => "plan",
      "id" => to_string(alternative.id)
    })

    assert_push_event(view, "home_adjustment_reset", %{})
    assert has_element?(view, "#home-summary", "Another workout")
    assert has_element?(view, "#home-action[aria-label='Start workout']")
  end

  test "Start creates the immutable server session before navigating by session id", %{
    conn: conn,
    user: user
  } do
    _recommendation = recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#home-action") |> render_click()

    session = Workouts.current_started_session(Scope.for_user(user))
    assert session.source_kind == :plan
    assert_redirect(view, ~p"/session/#{session.id}")
  end

  test "Start reuses the rendered token for duplicate delivery and rejects a forged token", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")

    [client_session_id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-action")
      |> LazyHTML.attribute("phx-value-client_session_id")

    params = %{
      "home_adjustment" => %{"instruction" => ""},
      "client_session_id" => client_session_id
    }

    render_click(
      view,
      "submit_home_action",
      Map.put(params, "client_session_id", Ecto.UUID.generate())
    )

    assert Repo.aggregate(WorkoutSession, :count) == 0

    render_click(view, "submit_home_action", params)

    [session] = Repo.all(WorkoutSession)

    assert {:ok, replayed} =
             Workouts.start_plan(
               Scope.for_user(user),
               session.plan_id,
               client_session_id
             )

    assert replayed.id == session.id
    assert Repo.aggregate(WorkoutSession, :count) == 1
    assert session.client_session_id == client_session_id
    assert_redirect(view, ~p"/session/#{session.id}")
  end

  test "today at target opens actual inline history, not another workout", %{
    conn: conn,
    user: user
  } do
    saved = complete_history(user, DateTime.utc_now(:second), 4_800)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-done-today")
    refute has_element?(view, "#home-week-complete")
    refute has_element?(view, "#home-action")
    assert has_element?(view, "#home-result-actual-seconds[data-duration-sec='4800']", "1:20:00")
    view = history_route(conn, view)
    assert has_element?(view, "#home-history-trend")
    # One workout type needs no legend; the line speaks for itself.
    refute has_element?(view, ".home-history-legend")
    assert has_element?(view, "#home-history-period-twelve_weeks[aria-pressed=true]")
    # A point opens its session in place in the list: the row has the numbers.
    view |> element("#home-history-point-#{saved.id}") |> render_click()

    assert has_element?(
             view,
             "#home-history-session-#{saved.id} #home-history-details-#{saved.id}"
           )

    assert has_element?(
             view,
             "#home-history-inspect-#{saved.id} .home-history-session-reps",
             "20"
           )

    assert has_element?(
             view,
             "#home-history-inspect-#{saved.id} .home-history-session-time",
             "1:20:00"
           )

    assert Repo.reload!(saved) == saved
  end

  test "History shows the density chart by default and swaps to saved sessions on request", %{
    conn: conn,
    user: user
  } do
    saved = complete_history(user, DateTime.utc_now(:second), 1_200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)

    assert has_element?(view, "#home-history-trend:not([hidden])")
    assert has_element?(view, "#home-history-sessions-panel[hidden]")
    view |> element("#home-history-density-sessions") |> render_click()
    assert has_element?(view, "#home-history-trend[hidden]")
    assert has_element?(view, "#home-history-sessions-panel:not([hidden])")
    assert has_element?(view, "#home-history-inspect-#{saved.id}")
    view |> element("#home-history-density-back") |> render_click()
    assert has_element?(view, "#home-history-trend:not([hidden])")
    assert has_element?(view, "#home-history-sessions-panel[hidden]")
  end

  test "a session opens and closes in place under its row, on one tap each", %{
    conn: conn,
    user: user
  } do
    saved = complete_history(user, DateTime.utc_now(:second), 1_200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    assert has_element?(view, "#home-history-inspect-#{saved.id}[aria-expanded=true]")
    assert has_element?(view, "#home-history-session-#{saved.id} #home-history-sheet")
    refute has_element?(view, "#home-history-body[inert], #home-history-close[inert]")
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    refute has_element?(view, "#home-history-sheet")
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    assert has_element?(view, "#home-history-sheet")
  end

  test "failed deletion says so in place and the session can still close", %{
    conn: conn,
    user: user
  } do
    saved = complete_history(user, DateTime.utc_now(:second), 1_200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    view |> element("#home-history-delete") |> render_click()
    Repo.delete!(saved)
    view |> element("#home-history-delete-confirm") |> render_click()
    # The session is gone, so its row is too; Progress says so at the top.
    assert has_element?(view, "#home-history-error[role=status]", "Couldn’t delete this session")
    refute has_element?(view, "#home-history-delete-confirm")
  end

  test "a weekly cell opens actual day minutes and returns to the grid", %{conn: conn, user: user} do
    saved = complete_history(user, DateTime.utc_now(:second), 1_200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)
    week = :sys.get_state(view.pid).socket.assigns.history_weeks |> List.last()
    day = DateTime.to_date(saved.completed_at)

    [open_commands] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-history-week-#{Date.to_iso8601(week.start)}")
      |> LazyHTML.attribute("phx-click")

    assert ["focus", %{"to" => "#home-history-week-mode"}] =
             hd(Jason.decode!(open_commands))

    view |> element("#home-history-week-#{Date.to_iso8601(week.start)}") |> render_click()
    assert has_element?(view, "#home-history-daily[aria-label='Daily training minutes']")
    refute has_element?(view, "#home-history-week-grid")

    assert has_element?(view, "#home-history-week-mode[phx-mounted]", "Weeks")

    refute has_element?(view, "#home-history-week-count, .home-history-week-key")
    assert has_element?(view, "#home-history-day-#{Date.to_iso8601(day)}")
    assert has_element?(view, "#home-history-week-detail strong", "20")

    assert has_element?(
             view,
             "#home-history-day-#{Date.to_iso8601(day)}[data-minutes='20']"
           )

    assert Repo.reload!(saved) == saved

    [commands] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-history-week-mode")
      |> LazyHTML.attribute("phx-click")

    assert ["push", %{"event" => "history_week_back"}] =
             List.last(Jason.decode!(commands))

    view |> element("#home-history-week-mode") |> render_click()
    refute has_element?(view, "#home-history-daily")
    assert has_element?(view, "#home-history-week-#{Date.to_iso8601(week.start)}")
  end

  test "History deletion requires confirmation and refreshes owned progress", %{
    conn: conn,
    user: user
  } do
    saved = complete_history(user, DateTime.utc_now(:second), 4_800)
    foreign = complete_history(user_fixture(), DateTime.utc_now(:second), 1200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)

    # Only this week has training, so the grid is this week alone, not a row of empty weeks.
    assert render(view)
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#home-history-weekly .home-history-week-cell")
           |> Enum.count() == 1

    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    assert has_element?(view, "#home-history-session-#{saved.id} #home-history-sheet")
    view |> element("#home-history-delete") |> render_click()
    assert has_element?(view, "#home-history-delete-confirm.home-danger-action", "Delete")
    view |> element("#home-history-delete-cancel") |> render_click()
    assert Repo.reload!(saved) == saved
    view |> element("#home-history-delete") |> render_click()
    view |> element("#home-history-delete-confirm") |> render_click()
    refute has_element?(view, "#home-history-close[inert]")
    refute has_element?(view, "#home-history-body[inert]")
    assert Repo.get(WorkoutSession, saved.id) == nil
    assert Repo.reload!(foreign) == foreign
    refute has_element?(view, "#home-history-inspect-#{saved.id}")
    assert has_element?(view, "#home-history-empty")
    refute has_element?(view, "#home-history-weekly")
    assert has_element?(view, "#home-history-close")
    view = home_route(conn, view)
    assert has_element?(view, "#home-week-track[aria-valuenow='0']")
  end

  test "Home priority renders done today before week complete", %{conn: conn, user: user} do
    complete_history(user, DateTime.utc_now(:second), 4_800)
    _recommendation = recommendation_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-done-today")
    refute has_element?(view, "#home-week-complete")
    refute has_element?(view, "#home-ready-recommendation")
  end

  test "done today renders before the workout-needed recommendation", %{conn: conn, user: user} do
    complete_history(user, DateTime.utc_now(:second), 1_200)
    _recommendation = recommendation_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-done-today")
    refute has_element?(view, "#home-ready-recommendation")
  end

  test "target-reaching today hides a persisted pending candidate and its actions", %{
    conn: conn,
    user: user
  } do
    ensure_candidate_history(user)
    recommendation = recommendation_fixture(user)
    slot = slot!(user)

    candidate =
      workout_plan_draft_fixture(user, %{
        definition: definition_for(slot, "Hidden after reaching today's target"),
        request_text: "Hidden after reaching today's target"
      })

    recommendation
    |> Ecto.Changeset.change(pending_draft_id: candidate.id)
    |> Repo.update!()

    complete_history(user, DateTime.utc_now(:second), 4_800)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-done-today")
    refute has_element?(view, "#home-week-complete")
    refute has_element?(view, "#home-pending-candidate")
    refute has_element?(view, "#use-candidate-button")
    refute has_element?(view, "#keep-current-workout-button")
  end

  test "done today hides a persisted pending candidate and its actions", %{conn: conn, user: user} do
    ensure_candidate_history(user)
    recommendation = recommendation_fixture(user)
    slot = slot!(user)

    candidate =
      workout_plan_draft_fixture(user, %{
        definition: definition_for(slot, "Hidden after today's workout"),
        request_text: "Hidden after today's workout"
      })

    recommendation
    |> Ecto.Changeset.change(pending_draft_id: candidate.id)
    |> Repo.update!()

    complete_history(user, DateTime.utc_now(:second), 1_200)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-done-today")
    refute has_element?(view, "#home-pending-candidate")
    refute has_element?(view, "#use-candidate-button")
    refute has_element?(view, "#keep-current-workout-button")
  end

  test "Resume uses the exact started session without creating another", %{conn: conn, user: user} do
    recommendation = recommendation_fixture(user)

    assert {:ok, started} =
             Workouts.start_plan(
               Scope.for_user(user),
               recommendation.selected_workout_plan_id,
               Ecto.UUID.generate()
             )

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#resume-recommended-workout[phx-value-session-id='#{started.id}']")

    assert has_element?(
             view,
             "#home-ready-recommendation[phx-hook='HomePendingSession'][data-session-id='#{started.id}'][data-content-hash='#{started.content_hash}']"
           )

    assert has_element?(view, "#home-session-state", "In progress")

    view |> element("#resume-recommended-workout") |> render_click()
    assert_redirect(view, ~p"/session/#{started.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "failed Resume restores a usable workspace when the rendered session disappears", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)

    {:ok, started} =
      Workouts.start_plan(
        Scope.for_user(user),
        recommendation.selected_workout_plan_id,
        Ecto.UUID.generate()
      )

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#resume-recommended-workout")
    refute has_element?(view, "#home-summary")

    Repo.delete!(started)
    view |> element("#resume-recommended-workout") |> render_click()

    refute has_element?(view, "#resume-recommended-workout")
    assert has_element?(view, "#home-summary")
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-expansion[data-open='true']")
    assert has_element?(view, "#home-inspection")
    assert has_element?(view, "#home-action[aria-label='Start workout']", "Start")
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "fresh mount shows the starter and its selection stays stable across reloads", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-workout-area")
    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    assert selected.plan.name == "Starter Six-Count"
    {:ok, reloaded, _} = live(conn, ~p"/")
    assert has_element?(reloaded, "#home-workout-area")
    {:ok, same} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    assert selected == same
  end

  test "expansion preserves DOM for both transition directions", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-expansion[data-open='false']")
    assert has_element?(view, "#home-expansion-content[inert][aria-hidden='true']")
    refute has_element?(view, "#desktop-home-nav")
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-expansion[data-open='true']")
    refute has_element?(view, "#home-expansion-content[inert]")
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-expansion-content[inert]")
    assert has_element?(view, "#home-inspection")
  end

  test "Home adjustment also waits for confirmed constraints before replacing the workout", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)

    extraction = %{
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    }

    layout = single_set_layout("Confirmed adjustment", "A shorter session.")

    counter =
      fake_authoring_provider(%{"workout_request" => extraction, "workout_layout" => layout})

    {:ok, view, _} = live(conn, ~p"/")
    original = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user)) |> elem(1)
    view |> element("#home-summary") |> render_click()

    view |> element("#home-new-workout") |> render_click()

    view |> element("#home-pill-pacing_style-even") |> render_click()

    view
    |> form("#home-new-form", home_workout: %{reps: 10, duration: "2:00"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#home-new-reps[disabled][value='10']")
    assert Agent.get(counter, & &1.calls) == ["workout_layout"]
    assert {:ok, ^original} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))

    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    assert has_element?(view, "#home-new-saved", "Confirmed adjustment")
    assert {:ok, ^original} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    assert Agent.get(counter, & &1.calls) == ["workout_layout"]
  end

  test "submit does not trust the previous Start label", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()

    view |> element("#home-new-workout") |> render_click()
    view |> form("#home-new-form", home_workout: %{note: "20 sets of 6"}) |> render_change()
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    assert has_element?(view, "#home-adjustment-error")
    view |> element("#home-request-abort") |> render_click()
    assert has_element?(view, "#home-action[aria-label='Start workout']", "Start")
  end

  test "blank submit starts despite prior Update label and old events cannot mutate", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")

    for event <- ["start_recommendation", "use_candidate", "keep_current"] do
      render_click(view, event, %{})
    end

    assert Workouts.current_started_session(Scope.for_user(user)) == nil

    view |> element("#home-action") |> render_click()

    session = Workouts.current_started_session(Scope.for_user(user))
    assert_redirect(view, ~p"/session/#{session.id}")
  end

  test "visible form actions retain accessible server-derived names and whitespace semantics", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()

    for instruction <- ["", "  \n\t", "Less rest"] do
      render_click(view, "change_adjustment", %{
        "home_adjustment" => %{"instruction" => instruction}
      })

      assert has_element?(view, "#home-action[type=button][aria-label='Start workout']", "Start")
    end

    view |> element("#home-title-action") |> render_click()

    assert has_element?(
             view,
             "#home-filter-toggle[aria-expanded=false]",
             "Filter"
           )

    view |> element("#home-filter-toggle") |> render_click()

    assert has_element?(
             view,
             "#home-filter-toggle[aria-expanded=true][aria-controls=home-filters]"
           )

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
  end

  test "malformed adjustment change is ignored", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "change_adjustment", %{"home_adjustment" => %{"instruction" => %{}}})
    assert has_element?(view, "#home-action[aria-label='Start workout']", "Start")
  end

  test "real missing-selection chooser preserves History and the mounted token", %{user: user} do
    complete_history(user, DateTime.add(DateTime.utc_now(:second), -90 * 86400), 1200)

    Repo.update_all(from(p in WorkoutPlan, where: is_nil(p.user_id) and p.origin == :built_in),
      set: [state: :archived, archived_at: DateTime.utc_now(:second)]
    )

    socket = mounted_socket(user)
    assert socket.assigns.home_selection == nil
    assert socket.assigns.home_state == :choose
    token = socket.assigns.start_client_session_id

    assert LazyHTML.query(render_home(socket), "#home-page[data-home-state=choose]")
           |> Enum.count() == 1

    assert LazyHTML.query(render_home(socket), "#home-title-action[data-primary-action=choose]")
           |> Enum.count() == 1

    assert {:noreply, opened} = workspace_screen(socket, :history)
    assert opened.assigns.history_open?
    assert opened.assigns.home_selection == nil
    assert opened.assigns.start_client_session_id == token
    html = render_home(opened)

    assert LazyHTML.query(html, "#home-history-heading[tabindex='-1'][phx-mounted]")
           |> Enum.count() == 1

    assert LazyHTML.query(html, "#home-history-empty") |> Enum.count() == 1
    assert LazyHTML.query(html, "#home-state-content") |> Enum.empty?()

    for event <- ["submit_home_action", "select_alternative", "toggle_summary", "start_collapsed"] do
      assert {:noreply, ^opened} = HomeLive.handle_event(event, %{}, opened)
    end

    assert {:noreply, filtered} =
             HomeLive.handle_event("history_period", %{"period" => "all"}, opened)

    assert filtered.assigns.history_period == "all"
    assert {:noreply, closing} = HomeLive.handle_event("close_history", %{}, filtered)
    assert closing.redirected == {:live, :patch, %{to: "/", kind: :push}}
    assert {:noreply, closed} = workspace_screen(%{closing | redirected: nil}, :home)
    refute closed.assigns.history_open?
    assert_workspace_unchanged(socket, closed)
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "busy History events preserve the workspace and do not bypass workout guards", %{
    user: user
  } do
    id = make_ref()
    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    complete_history(user, DateTime.add(DateTime.utc_now(:second), -90 * 86400), 1200)
    socket = mounted_socket(user)
    assert socket.assigns.home_selection == selected

    {:noreply, socket} =
      HomeLive.handle_event(
        "change_adjustment",
        %{"home_adjustment" => %{"instruction" => "Less rest"}},
        socket
      )

    socket =
      Phoenix.Component.assign(socket,
        busy?: true,
        update_id: id,
        expanded?: true,
        alternatives_open?: true,
        filters_open?: true,
        expanded_groups: MapSet.new(["kept-group"]),
        history_expanded: MapSet.new([123])
      )

    assert_shared_progress(render_home(socket))
    assert {:noreply, opened} = workspace_screen(socket, :history)
    assert opened.assigns.history_open?
    assert_workspace_unchanged(socket, opened)
    assert opened.assigns.history_expanded == MapSet.new([123])
    html = render_home(opened)
    assert LazyHTML.query(html, "#home-history-heading") |> Enum.count() == 1
    assert LazyHTML.query(html, "#home-state-content, #home-update-loading") |> Enum.empty?()

    for event <- [
          "submit_home_action",
          "select_alternative",
          "resume_recommendation",
          "retry_recommendation"
        ] do
      assert {:noreply, ^opened} = HomeLive.handle_event(event, %{}, opened)
    end

    assert {:noreply, changed} =
             HomeLive.handle_event("history_period", %{"period" => "all"}, opened)

    assert changed.assigns.history_period == "all"
    assert changed.assigns.history_expanded == MapSet.new()
    assert_workspace_unchanged(socket, changed)
    assert {:noreply, ^changed} = HomeLive.handle_event("history_more", %{}, changed)
    assert {:noreply, closing} = HomeLive.handle_event("close_history", %{}, changed)
    assert {:noreply, closed} = workspace_screen(%{closing | redirected: nil}, :home)
    refute closed.assigns.history_open?
    assert_workspace_unchanged(socket, closed)

    assert {:noreply, finished} =
             HomeLive.handle_async(
               {:home_revision, id},
               {:ok, {:error, :unavailable}},
               opened
             )

    assert finished.assigns.history_open?
    assert finished.assigns.history_expanded == opened.assigns.history_expanded
    assert finished.assigns.instruction == "Less rest"
    assert finished.assigns.home_selection == socket.assigns.home_selection
    assert finished.assigns.start_client_session_id == socket.assigns.start_client_session_id

    assert {:noreply, revised} =
             HomeLive.handle_async(
               {:home_revision, id},
               {:ok, {:ok, socket.assigns.home_selection}},
               opened
             )

    assert revised.assigns.history_open?
    assert revised.assigns.history_expanded == opened.assigns.history_expanded
    assert revised.assigns.history_period == opened.assigns.history_period
    assert revised.assigns.history_points == opened.assigns.history_points
    assert revised.assigns.history_summary == opened.assigns.history_summary
    assert revised.assigns.history_loaded_ids == opened.assigns.history_loaded_ids
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "History loads owned saved-page counts and ignores closed or malformed controls", %{
    user: user
  } do
    now = ~U[2026-09-09 12:00:00Z]
    sessions = for _ <- 1..7, do: complete_history(user, now, 1200)
    complete_history(user_fixture(), now, 1200)
    socket = mounted_socket(user) |> Phoenix.Component.assign(home_now: fn -> now end)

    for {event, params} <- [
          {"history_period", %{"period" => "all"}},
          {"history_more", %{}},
          {"history_period", %{"period" => "bogus"}},
          {"history_period", %{}},
          {"history_session", %{"id" => "bogus"}}
        ] do
      assert {:noreply, ^socket} = HomeLive.handle_event(event, params, socket)
    end

    {:noreply, opened} = workspace_screen(socket, :history, %{"return_to" => "#untrusted"})

    assert LazyHTML.query(
             render_home(opened),
             "#home-history-close[phx-click=close_history][aria-label='Back to Home']"
           )
           |> Enum.count() == 1

    assert opened.assigns.history_loaded_count == 5
    assert opened.assigns.history_has_more?
    assert LazyHTML.query(render_home(opened), "#home-history-count") |> LazyHTML.text() =~ "5"

    assert Enum.map(opened.assigns.history_points.six_count, & &1.id) ==
             Enum.map(sessions, & &1.id)

    assert opened.assigns.history_points.navy_seal == []

    assert opened.assigns.history_summary == %{
             sessions: 7,
             total_reps: 140,
             active_time_sec: 8_400,
             latest_density: 20
           }

    {:noreply, more} = HomeLive.handle_event("history_more", %{}, opened)
    assert more.assigns.history_loaded_count == 7
    assert more.assigns.history_summary == opened.assigns.history_summary
    assert more.assigns.history_loaded_ids == sessions |> Enum.map(& &1.id) |> Enum.reverse()
    refute more.assigns.history_has_more?
    assert {:noreply, ^more} = HomeLive.handle_event("history_more", %{}, more)
    {:noreply, closed} = HomeLive.handle_event("close_history", %{}, more)
    assert closed.assigns.history_loaded_ids == more.assigns.history_loaded_ids

    {:noreply, reopened} = workspace_screen(%{closed | redirected: nil}, :history)

    assert LazyHTML.query(render_home(reopened), "#home-history-close[phx-click=close_history]")
           |> Enum.count() == 1

    assert reopened.assigns.history_loaded_count == 5
    assert_workspace_unchanged(socket, reopened)
    assert Repo.aggregate(WorkoutSession, :count) == 8
  end

  test "History range changes weekly grid and session summaries together", %{user: user} do
    now = ~U[2026-09-23 12:00:00Z]
    recent = complete_history(user, now, 1200)
    previous_year = complete_history(user, ~U[2025-08-01 12:00:00Z], 1200)
    socket = mounted_socket(user) |> Phoenix.Component.assign(home_now: fn -> now end)
    {:noreply, recent_view} = workspace_screen(socket, :history)
    # The grid starts at the first week with training: only this week in the last 12.
    assert length(recent_view.assigns.history_weeks) == 1
    assert recent_view.assigns.history_summary.sessions == 1
    assert recent.id in Enum.map(recent_view.assigns.history_points.six_count, & &1.id)
    refute previous_year.id in Enum.map(recent_view.assigns.history_points.six_count, & &1.id)

    {:noreply, year_view} =
      HomeLive.handle_event("history_period", %{"period" => "year"}, recent_view)

    assert length(year_view.assigns.history_weeks) == 1
    assert year_view.assigns.history_summary.sessions == 1

    {:noreply, all_view} =
      HomeLive.handle_event("history_period", %{"period" => "all"}, year_view)

    assert length(all_view.assigns.history_weeks) > 52
    assert all_view.assigns.history_summary.sessions == 2
    assert length(all_view.assigns.history_points.six_count) == 2
  end

  test "History read failure stays closable without changing the mounted workspace", %{user: user} do
    complete_history(user, DateTime.add(DateTime.utc_now(:second), -90 * 86400), 1200)
    socket = mounted_socket(user)
    invalid_user = %{user | timezone: "Invalid/Zone"}

    socket =
      Phoenix.Component.assign(socket,
        current_scope: BurpeeTrainer.Accounts.Scope.for_user(invalid_user)
      )

    {:noreply, opened} = workspace_screen(socket, :history)
    assert opened.assigns.history_error
    assert opened.assigns.history_loaded_count == 0
    assert opened.assigns.history_points == %{six_count: [], navy_seal: []}

    assert opened.assigns.history_summary == %{
             sessions: 0,
             total_reps: 0,
             active_time_sec: 0,
             latest_density: nil
           }

    assert opened.assigns.history_cursor == nil
    refute opened.assigns.history_has_more?
    html = render_home(opened)
    assert LazyHTML.query(html, "#home-history-error") |> Enum.count() == 1
    assert LazyHTML.query(html, "#home-history-empty, #home-history-count") |> Enum.empty?()

    assert LazyHTML.query(
             html,
             "#home-history-close[aria-label='Back to Home'][phx-click=close_history]"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(html, "#home-state-content, #home-history-toggle") |> Enum.empty?()

    {:noreply, closing} = HomeLive.handle_event("close_history", %{}, opened)
    {:noreply, closed} = workspace_screen(%{closing | redirected: nil}, :home)
    refute closed.assigns.history_open?
    assert_workspace_unchanged(socket, closed)
  end

  test "repeated History opening restores isolation commands before push and closing reveals before focus",
       %{
         conn: conn,
         user: user
       } do
    complete_history(user, DateTime.add(DateTime.utc_now(:second), -90 * 86400), 1200)
    {:ok, view, _} = live(conn, ~p"/")
    before = :sys.get_state(view.pid).socket

    # Inspect real client commands as well as server patch handling: no retired overlay DOM.
    for _cycle <- 1..3 do
      assert has_element?(view, "#home-history-toggle[href='/progress'][data-phx-link=patch]")
      view = history_route(conn, view)
      assert view.pid == before.root_pid
      html = render(view) |> LazyHTML.from_fragment()

      [commands] =
        LazyHTML.query(html, "#home-history-heading") |> LazyHTML.attribute("phx-mounted")

      assert [["focus", %{"to" => "#home-history-heading"}]] = Jason.decode!(commands)
      assert has_element?(view, "#history-page[phx-window-keydown=close_history][phx-key=Escape]")
      assert has_element?(view, "#home-history-close[phx-click=close_history]")
      refute has_element?(view, "#home-state-content, #home-coach-panel")
      view = home_route(conn, view)
      refute has_element?(view, "#home-history")
      assert has_element?(view, "#home-state-content:not([hidden]):not([inert])")

      [commands] =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#home-history-toggle")
        |> LazyHTML.attribute("phx-mounted")

      assert [["focus", %{"to" => "#home-history-toggle"}]] = Jason.decode!(commands)
      assert has_element?(view, "#home-history-toggle[aria-label='Open Progress']")
      after_close = :sys.get_state(view.pid).socket
      assert_workspace_unchanged(before, after_close)
      assert after_close.redirected == nil
    end
  end

  test "shared progress survives valid today, week-complete and started presentation states", %{
    user: user
  } do
    now = ~U[2026-09-09 12:00:00Z]
    {:ok, _selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    complete_history(user, DateTime.add(now, -90 * 86400), 1200)
    socket = mounted_socket(user, now)
    selection = socket.assigns.home_selection

    complete_history(user, DateTime.add(now, -86400), 4800)
    {:ok, week_slot} = Policy.required_slot(Scope.for_user(user), now)
    assert week_slot.home_state == :week_complete
    week_socket = mounted_socket(user, now)
    assert_shared_progress(render_home(week_socket))
    assert LazyHTML.query(render_home(week_socket), "#home-week-complete") |> Enum.count() == 1

    complete_history(user, now, 1200)
    {:ok, today_slot} = Policy.required_slot(Scope.for_user(user), now)
    assert today_slot.home_state == :done_today
    today_socket = mounted_socket(user, now)

    {:ok, started} =
      Workouts.start_plan(Scope.for_user(user), selection.plan.id, Ecto.UUID.generate())

    started_socket = mounted_socket(user, now)
    assert started_socket.assigns.started_session.id == started.id
    assert_shared_progress(render_home(started_socket))

    assert LazyHTML.query(render_home(started_socket), "#resume-recommended-workout")
           |> Enum.count() == 1

    for state <- [week_socket, today_socket, started_socket] do
      {:noreply, opened} = workspace_screen(state, :history)
      assert LazyHTML.query(render_home(opened), "#home-history-heading") |> Enum.count() == 1

      assert LazyHTML.query(render_home(opened), "#home-state-content")
             |> Enum.empty?()

      assert opened.assigns.history_loaded_count == 2
      {:noreply, closing} = HomeLive.handle_event("close_history", %{}, opened)
      {:noreply, closed} = workspace_screen(%{closing | redirected: nil}, :home)
      assert_shared_progress(render_home(closed))
      assert_workspace_unchanged(state, closed)
    end
  end

  test "History inspection reconciles retained rows without resetting their DOM stream", %{
    user: user
  } do
    now = DateTime.utc_now(:second)
    rows = for _ <- 1..7, do: complete_history(user, now, 1200)
    {:noreply, opened} = workspace_screen(mounted_socket(user), :history)
    loaded = opened.assigns.history_loaded_ids
    oldest = hd(rows)
    retained_id = hd(loaded)
    cursor = opened.assigns.history_cursor

    Enum.reduce([retained_id, retained_id, oldest.id, oldest.id], opened, fn id, socket ->
      # Direct callbacks need the same pruning that LiveView performs after rendering.
      streams =
        Map.update!(
          socket.assigns.streams,
          :history_sessions,
          &Phoenix.LiveView.LiveStream.prune/1
        )

      socket = %{socket | assigns: Map.put(socket.assigns, :streams, streams)}

      {:noreply, inspected} =
        HomeLive.handle_event("history_session", %{"id" => to_string(id)}, socket)

      refute inspected.assigns.streams.history_sessions.reset?
      assert inspected.assigns.streams.history_sessions.deletes == []
      assert inspected.assigns.history_cursor == cursor
      assert inspected.assigns.history_loaded_ids == Enum.sort(Enum.uniq(loaded ++ [id]), :desc)

      assert MapSet.member?(inspected.assigns.history_expanded, id) !=
               MapSet.member?(socket.assigns.history_expanded, id)

      for row <- rows, do: assert(Repo.reload!(row) == row)
      inspected
    end)
  end

  test "older chart inspection and repeated pages retain sorted unique rows and expansion", %{
    conn: conn,
    user: user
  } do
    now = DateTime.utc_now(:second)
    sessions = for seconds <- 1..12, do: complete_history(user, DateTime.add(now, -seconds), 1200)
    newest = hd(sessions)
    oldest = List.last(sessions)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)
    view |> element("#home-history-period-all") |> render_click()
    refute has_element?(view, "#home-history-session-#{oldest.id}")
    cursor = :sys.get_state(view.pid).socket.assigns.history_cursor
    view |> element("#home-history-point-#{oldest.id}") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.history_cursor == cursor
    assert has_element?(view, "#home-history-details-#{oldest.id}")
    view |> element("#home-history-point-#{newest.id}") |> render_click()

    for expected_count <- [11, 12] do
      assert has_element?(view, "#home-history-more[phx-disable-with='Loading sessions…']")
      view |> element("#home-history-more") |> render_click()

      ids =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#home-history-sessions > tr")
        |> LazyHTML.attribute("id")

      expected =
        sessions
        |> Enum.take(expected_count - 1)
        |> Kernel.++([oldest])
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(&"home-history-session-#{&1.id}")

      assert ids == expected
      assert length(ids) == expected_count
      assert has_element?(view, "#home-history-details-#{newest.id}")
    end

    refute has_element?(view, "#home-history-more")
    refute has_element?(view, "#home-history-pagination-terminal")
    view |> element("#home-history-inspect-#{oldest.id}") |> render_click()
    refute has_element?(view, "#home-history-details-#{oldest.id}")
    refute has_element?(view, "#home-history-details-#{newest.id}")
    for saved <- sessions, do: assert(Repo.reload!(saved) == saved)
  end

  test "History inspection ignores hostile or hidden IDs and never mutates sessions", %{
    conn: conn,
    user: user
  } do
    now = DateTime.utc_now(:second)
    owned = complete_history(user, now, 1200)
    foreign = complete_history(user_fixture(), now, 1200)
    deleted = complete_history(user, now, 1200)
    Repo.delete!(deleted)

    plan = workout_plan_draft_fixture(user)
    plan = plan |> WorkoutPlan.publish_changeset(DateTime.utc_now(:second)) |> Repo.update!()
    {:ok, started} = Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    old = complete_history(user, DateTime.add(now, -100 * 86400), 1200)
    future = complete_history(user, DateTime.add(now, 3600), 1200)
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "history_session", %{"id" => to_string(owned.id)})
    refute has_element?(view, "#home-history, #home-history-sheet")
    assert Repo.reload!(owned) == owned
    view = history_route(conn, view)
    before = :sys.get_state(view.pid).socket.assigns

    for params <- [
          %{},
          %{"id" => "1junk"},
          %{"id" => "-1"},
          %{"id" => "0"},
          %{"id" => %{}},
          %{"id" => to_string(foreign.id)},
          %{"id" => to_string(deleted.id)},
          %{"id" => to_string(started.id)},
          %{"id" => to_string(old.id)},
          %{"id" => to_string(future.id)}
        ] do
      render_click(view, "history_session", params)
      after_event = :sys.get_state(view.pid).socket.assigns
      assert after_event.history_expanded == before.history_expanded
      assert after_event.history_loaded_ids == before.history_loaded_ids
    end

    render_click(view, "history_period", %{"period" => "unknown"})
    assert has_element?(view, "#home-history-period-twelve_weeks[aria-pressed=true]")

    for rejected <- [foreign, deleted, started, old, future] do
      refute has_element?(view, "#home-history-session-#{rejected.id}")
    end

    assert Repo.get(WorkoutSession, deleted.id) == nil
    for saved <- [owned, foreign, started, old, future], do: assert(Repo.reload!(saved) == saved)
  end

  test "restream drops deleted, noncompleted and newly out-of-period displayed rows", %{
    user: user
  } do
    now = ~U[2026-09-09 12:00:00Z]
    {:ok, _selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    deleted = complete_history(user, now, 1200)
    _previous_week = complete_history(user, now, 1200)
    socket = mounted_socket(user) |> Phoenix.Component.assign(home_now: fn -> now end)

    {:ok, started} =
      Workouts.start_plan(
        Scope.for_user(user),
        socket.assigns.home_selection.plan.id,
        Ecto.UUID.generate()
      )

    next_week = DateTime.add(now, 12 * 7 * 86400)
    kept = complete_history(user, next_week, 1200)
    {:noreply, opened} = workspace_screen(socket, :history)
    Repo.delete!(deleted)
    # Exercise the defensive retained-ID seam without violating immutable completion triggers.
    opened =
      Phoenix.Component.assign(opened,
        history_loaded_ids: opened.assigns.history_loaded_ids ++ [started.id],
        home_now: fn -> next_week end
      )

    {:noreply, inspected} =
      HomeLive.handle_event("history_session", %{"id" => to_string(kept.id)}, opened)

    assert inspected.assigns.history_loaded_ids == [kept.id]
    assert inspected.assigns.history_loaded_count == 1
    assert MapSet.member?(inspected.assigns.history_expanded, kept.id)
  end

  test "busy inspection remains read-only and re-renders details", %{user: user} do
    saved = complete_history(user, DateTime.utc_now(:second), 1200)
    socket = mounted_socket(user) |> Phoenix.Component.assign(busy?: true)
    {:noreply, opened} = workspace_screen(socket, :history)

    {:noreply, inspected} =
      HomeLive.handle_event("history_session", %{"id" => to_string(saved.id)}, opened)

    assert MapSet.member?(inspected.assigns.history_expanded, saved.id)
    assert_workspace_unchanged(socket, inspected)
    assert Repo.reload!(saved) == saved
  end

  test "today actual totals and streamed session details use both types without a second Start",
       %{conn: conn, user: user} do
    now = DateTime.utc_now(:second)
    first = complete_history(user, now, 600)

    second =
      complete_history(user, now, 900,
        burpee_type: :navy_seal,
        workout_type_snapshot: :navy_seal,
        burpee_count_actual: 7,
        display_name_snapshot: "Evening sets",
        mood: 1
      )

    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#home-done-today .home-state-label")
    assert has_element?(view, "#home-done-today h1", "Evening sets")
    refute has_element?(view, "#home-done-today h1", "Workout saved")
    assert has_element?(view, "#home-today-session-meta", "15:00 · 7 reps")
    assert has_element?(view, "#home-today-mood", "Good")

    assert has_element?(
             view,
             "#home-result-actual-seconds[data-duration-sec='1500']",
             "25:00 · 27 reps"
           )

    refute has_element?(view, "#home-result-sessions, #home-result-history")
    refute has_element?(view, "#home-action, #home-other-workouts")

    view = history_route(conn, view)
    refute has_element?(view, "#home-state-content")
    assert has_element?(view, "#home-history-close[phx-click=close_history]")

    for row <- [first, second] do
      assert has_element?(view, "#home-history-inspect-#{row.id}")
    end

    view = home_route(conn, view)
    assert has_element?(view, "#home-state-content:not([hidden]):not([inert])")
  end

  test "unfinished session stays reachable even after today's target", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)

    {:ok, started} =
      Workouts.start_plan(
        Scope.for_user(user),
        recommendation.selected_workout_plan_id,
        Ecto.UUID.generate()
      )

    complete_history(user, DateTime.utc_now(:second), 4800)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#resume-recommended-workout[phx-value-session-id='#{started.id}']")
    refute has_element?(view, "#home-done-today, #home-week-complete, #home-action")
    view = history_route(conn, view)
    view = home_route(conn, view)

    render_click(view, "submit_home_action", %{
      "client_session_id" => Ecto.UUID.generate(),
      "home_adjustment" => %{"instruction" => ""}
    })

    assert Workouts.current_started_session(Scope.for_user(user)).id == started.id
    assert Repo.reload!(started) == started
    assert Repo.aggregate(WorkoutSession, :count) == 2
    view |> element("#resume-recommended-workout") |> render_click()
    assert_redirect(view, ~p"/session/#{started.id}")
  end

  test "unfinished Home video keeps its exact route and snapshot after today's target", %{
    conn: conn,
    user: user
  } do
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(user), slot!(user))
    video = video_fixture(%{duration_sec: 1200, burpee_count: 60})

    {:ok, started} =
      Workouts.start_home_video(Scope.for_user(user), shown, video.id, Ecto.UUID.generate())

    complete_history(user, DateTime.utc_now(:second), 4800)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#resume-recommended-workout[phx-value-session-id='#{started.id}']")
    refute has_element?(view, "#home-done-today, #home-week-complete, #home-action")
    view = history_route(conn, view)
    view |> element("#home-history-period-all") |> render_click()
    view = home_route(conn, view)

    render_click(view, "submit_home_action", %{
      "client_session_id" => Ecto.UUID.generate(),
      "home_adjustment" => %{"instruction" => ""}
    })

    render_click(view, "select_alternative", %{"kind" => "video", "id" => to_string(video.id)})
    assert Workouts.current_started_session(Scope.for_user(user)).id == started.id
    assert Repo.reload!(started) == started
    assert started.source_kind == :video
    assert started.workout_video_id == video.id
    assert Repo.aggregate(WorkoutSession, :count) == 2
    view |> element("#resume-recommended-workout") |> render_click()
    assert_redirect(view, ~p"/videos/#{video.id}/session/#{started.id}")
  end

  test "prior-day weekly result labels exact credit separately from actual type reps", %{
    user: user
  } do
    now = ~U[2026-09-09 12:00:00Z]
    yesterday = DateTime.add(now, -86400)
    complete_history(user, yesterday, 4701)

    complete_history(user, yesterday, 100,
      burpee_type: :navy_seal,
      workout_type_snapshot: :navy_seal,
      burpee_count_actual: 9
    )

    complete_history(user, yesterday, 600, tags: "warmup", burpee_count_actual: 5)
    socket = mounted_socket(user, now)
    html = render_home(socket)
    assert LazyHTML.query(html, "#home-week-complete") |> Enum.count() == 1

    assert LazyHTML.query(html, "#home-result-actual-seconds") |> LazyHTML.text() |> String.trim() ==
             "1:20:01 · 34 reps"

    assert LazyHTML.query(html, "#home-result-actual-seconds") |> LazyHTML.text() =~
             "34 reps"

    assert LazyHTML.query(
             html,
             "#home-result-sessions, #home-result-history, #home-result-six-count-reps, #home-result-navy-seal-reps"
           )
           |> Enum.empty?()

    assert LazyHTML.query(html, "#home-action, #home-other-workouts, #home-done-today")
           |> Enum.empty?()

    assert LazyHTML.query(
             html,
             "#home-week-track[aria-valuenow='4800'][aria-valuetext='4801 of 4800 seconds completed']"
           )
           |> Enum.count() == 1

    refute Map.has_key?(socket.assigns, :result_sessions)
  end

  defp history_route(_conn, view) do
    view |> element("#home-history-toggle") |> render_click()
    assert_patch(view, "/progress")
    refute has_element?(view, "#home-state-content")
    assert has_element?(view, "#home-history-heading[tabindex='-1'][phx-mounted]")
    view
  end

  defp home_route(_conn, view) do
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    view
  end

  defp mounted_socket(user, now \\ DateTime.utc_now(:second)) do
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

  defp render_home(socket),
    do: render_component(&HomeLive.render/1, socket.assigns) |> LazyHTML.from_fragment()

  defp assert_shared_progress(html) do
    assert LazyHTML.query(html, ".adaptive-home") |> Enum.count() == 1
    assert LazyHTML.query(html, "#home-week-track[role=progressbar]") |> Enum.count() == 1

    label =
      if LazyHTML.query(html, "#home-history") |> Enum.empty?(),
        do: "Open Progress",
        else: "Close History"

    assert LazyHTML.query(html, "#home-history-toggle[href='/progress'][aria-label='#{label}']")
           |> Enum.count() == 1

    assert LazyHTML.query(
             html,
             "#home-history-toggle [role=progressbar], #home-state-content #home-week-track"
           )
           |> Enum.empty?()
  end

  defp assert_workspace_unchanged(before, after_socket) do
    keys = [
      :home_selection,
      :start_client_session_id,
      :instruction,
      :adjustment_form,
      :expanded?,
      :expanded_groups,
      :filters,
      :filters_open?,
      :alternatives_open?,
      :active_tab,
      :busy?,
      :update_id,
      :started_session,
      :slot
    ]

    assert Map.take(before.assigns, keys) == Map.take(after_socket.assigns, keys)
  end

  test "History sheet displays only feedback persisted on the selected session", %{
    conn: conn,
    user: user
  } do
    completed_at = DateTime.utc_now(:second)

    tagged =
      complete_history(user, completed_at, 1_200,
        tags: "heat, low_energy",
        note_post: "Kept going"
      )

    plain = complete_history(user, DateTime.add(completed_at, -1, :second), 1_200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)
    view |> element("#home-history-density-sessions") |> render_click()

    view |> element("#home-history-inspect-#{tagged.id}") |> render_click()
    assert has_element?(view, "#home-history-session-#{tagged.id} #home-history-sheet")
    assert has_element?(view, "#home-history-sheet-tags", "Heat")
    assert has_element?(view, "#home-history-sheet-tags", "Low energy")
    assert has_element?(view, "#home-history-sheet-note", "Kept going")

    view |> element("#home-history-inspect-#{plain.id}") |> render_click()
    refute has_element?(view, "#home-history-sheet-tags")
    refute has_element?(view, "#home-history-sheet-note")
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

  defp recommendation_fixture(user) do
    slot = slot!(user)

    {:ok, recommendation} =
      Workouts.ensure_recommendation(Scope.for_user(user), %{
        slot_key: slot.slot_key,
        slot_date: slot.slot_date,
        rationale: "A steady workout for today."
      })

    recommendation
  end

  defp slot!(user) do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    slot
  end

  # Catch-up candidates need a real prior best, without crediting this week's target.
  defp ensure_candidate_history(user) do
    slot = slot!(user)

    if slot.strategy == :catch_up do
      definition =
        definition_for(%{slot | strategy: :standard, duration_sec: 1_200}, "Prior-week PB")

      draft = workout_plan_draft_fixture(user, %{definition: definition})
      plan = draft |> WorkoutPlan.publish_changeset(DateTime.utc_now(:second)) |> Repo.update!()

      {:ok, completed_at} =
        BurpeeTrainer.UserTime.resolve_local(
          Date.add(slot.week_start, -1),
          ~T[12:00:00],
          user.timezone
        )

      %WorkoutSession{
        user_id: user.id,
        state: :started,
        source_kind: :plan,
        plan_id: plan.id,
        client_session_id: Ecto.UUID.generate(),
        display_name_snapshot: plan.name,
        workout_type_snapshot: plan.burpee_type,
        program_snapshot: plan.program_json,
        content_hash: plan.content_hash,
        burpee_type: plan.burpee_type,
        burpee_count_planned: plan.target_reps,
        duration_sec_planned: plan.target_duration_sec,
        started_at: DateTime.add(completed_at, -1_200, :second)
      }
      |> WorkoutSession.start_changeset()
      |> Repo.insert!()
      |> WorkoutSession.completion_changeset(
        %{"burpee_count_actual" => plan.target_reps, "duration_sec_actual" => 1_200},
        completed_at
      )
      |> Repo.update!()

      refreshed = slot!(user)
      assert refreshed.completed_sec == 0
      assert refreshed.personal_best.reps == plan.target_reps
    end
  end

  defp single_set_layout(name, rationale) do
    %{
      "name" => name,
      "rationale" => rationale,
      "phases" => [
        %{
          "sets" => [%{"reps" => 10, "sec_per_rep" => 12, "sec_per_burpee" => 12}],
          "rest_weights" => []
        }
      ]
    }
  end

  defp fake_authoring_provider(responses) do
    original = Application.fetch_env!(:burpee_trainer, :llm_provider)
    on_exit(fn -> Application.put_env(:burpee_trainer, :llm_provider, original) end)

    counter = start_supervised!({Agent, fn -> %{responses: responses, calls: []} end})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    start_supervised!(
      {Bandit,
       plug: {BurpeeTrainer.TestAuthoringProviderPlug, counter: counter},
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    )

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "http://127.0.0.1:#{port}/chat/completions",
      api_key: "test-key",
      model: "test-model",
      timeout_ms: 20_000
    )

    counter
  end

  defp definition_for(slot, name) do
    reps =
      if slot.strategy == :catch_up do
        {:ok, prescription} =
          BurpeeTrainer.Coach.CatchUpPolicy.prescription(
            slot.duration_sec,
            slot.personal_best.reps,
            %{}
          )

        prescription.ceiling_reps
      else
        10
      end

    cadence = slot.duration_sec / reps

    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => Atom.to_string(slot.burpee_type),
      "target_duration_sec" => slot.duration_sec,
      "target_reps" => reps,
      "pacing_style" => "even",
      "rationale" => "A measured reusable workout.",
      "events" => [
        %{
          "kind" => "work",
          "reps" => reps,
          "sec_per_rep" => cadence,
          "sec_per_burpee" => cadence
        }
      ]
    }
  end
end
