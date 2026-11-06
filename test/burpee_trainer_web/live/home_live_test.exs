defmodule BurpeeTrainerWeb.HomeLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  import BurpeeTrainerWeb.StudioHelpers

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Memory, Policy}
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}
  alias BurpeeTrainerWeb.HomeLive

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "the coach speaks on Home once today is done", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#home-coach-panel")

    free_form_session_fixture(user, %{duration_sec_actual: 1_200})
    {:ok, view, _} = live(conn, ~p"/")
    # The coach sits open under the result; there is nothing to tap to reach it.
    assert has_element?(view, "#home-done-today ~ #home-coach-panel")
    refute has_element?(view, "#home-done-summary[aria-expanded]")
    assert has_element?(view, "#home-coach-message-form")
    assert Memory.list(Scope.for_user(user)) == []
  end

  test "invalid guidance remains editable and can be corrected and saved", %{
    conn: conn,
    user: user
  } do
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})
    {:ok, view, _} = live(conn, ~p"/")
    view |> form("#home-coach-message-form", coach_message: %{text: "  "}) |> render_submit()
    assert has_element?(view, "#home-coach-status[role=status]", "Enter a message")
    assert Memory.list(Scope.for_user(user)) == []
    long_text = String.duplicate("x", 1001)

    view
    |> form("#home-coach-message-form", coach_message: %{text: long_text})
    |> render_submit()

    assert has_element?(view, "#home-coach-message-text", long_text)
    assert Memory.list(Scope.for_user(user)) == []

    view
    |> form("#home-coach-message-form", coach_message: %{text: "Keep sets shorter"})
    |> render_submit()

    render_async(view)
    assert Memory.list(Scope.for_user(user)) == []
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

    {:ok, linked_view, _} = live(conn, ~p"/progress")
    assert has_element?(linked_view, "#home-history-empty")
  end

  test "the camera and warmup toggles sit beside play, collapsed or expanded", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _html} = live(conn, ~p"/")

    for {id, choice, label, icon} <- [
          {"home-start-camera", "camera", "Camera tracking", "hero-video-camera"},
          {"home-start-warmup", "warmup", "Warmup", "hero-fire"}
        ] do
      selector =
        ".home-workout-actions ##{id}[type=button][phx-hook=HomeStartChoice]" <>
          "[phx-update=ignore][data-start-choice=#{choice}][aria-pressed]" <>
          "[aria-label='#{label}'] .#{icon}"

      assert has_element?(view, selector)
      refute has_element?(view, "##{id}[inert]")
      refute has_element?(view, "##{id}.home-expanded-action")
    end

    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-start-camera")
    assert has_element?(view, "#home-start-warmup")

    open_new(view)
    refute has_element?(view, "#home-start-camera")
    refute has_element?(view, "#home-start-warmup")
  end

  test "the start toggles render as this device remembers them, from the first paint", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)

    conn =
      conn
      |> put_req_cookie("burpee_start_camera", "1")
      |> put_req_cookie("burpee_start_warmup", "0")

    # The page load, before any script runs.
    page = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.attribute(page["#home-start-camera"], "aria-pressed") == ["true"]
    assert LazyHTML.attribute(page["#home-start-warmup"], "aria-pressed") == ["false"]

    # The join, with the choices the browser reads from the same cookies.
    {:ok, view, _} =
      conn
      |> put_connect_params(%{"start_choices" => %{"camera" => true, "warmup" => false}})
      |> live(~p"/")

    assert has_element?(view, "#home-start-camera[aria-pressed=true]")
    assert has_element?(view, "#home-start-warmup[aria-pressed=false]")

    # A tap on the device, then New and back: the toggles come back as they were left.
    render_hook(view, "start_choice", %{"choice" => "warmup", "pressed" => true})
    open_new(view)
    refute has_element?(view, "#home-start-warmup")
    view |> element(".studio-foot-close") |> render_click()
    assert has_element?(view, "#home-start-camera[aria-pressed=true]")
    assert has_element?(view, "#home-start-warmup[aria-pressed=true]")
  end

  test "the drawer's tabs sit above its list, which says when a tab is empty", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-alternatives-panel[hidden] #home-alternatives-toolbar")
    refute has_element?(view, "#home-other-workouts")
    open_swap(view)

    assert has_element?(
             view,
             "#home-alternatives-panel:not([hidden]) #home-alternatives-toolbar > [role=tablist]"
           )

    assert has_element?(view, "#home-alternatives-toolbar ~ #home-alternatives")
    assert has_element?(view, "#home-tab-workouts[role=tab][aria-selected=true]")
    assert has_element?(view, "#home-week-track[role=progressbar][aria-valuemax='4800']")
    view |> element("#home-tab-videos") |> render_click()

    empty_text =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-alternatives-empty")
      |> LazyHTML.text()
      |> String.trim()

    assert empty_text == "No videos yet."
    assert has_element?(view, "#home-tab-videos[role=tab][aria-selected=true]")
  end

  test "alternative rows carry real metadata; a tap uses a workout or starts a video", %{
    conn: conn,
    user: user
  } do
    recommendation = recommendation_fixture(user)
    plan = Repo.get!(BurpeeTrainer.Workouts.WorkoutPlan, recommendation.selected_workout_plan_id)
    video = video_fixture(%{duration_sec: 1200, burpee_count: 60})
    unknown = video_fixture()
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    open_swap(view)

    assert has_element?(
             view,
             "#home-alternative-plan-#{plan.id} .home-alternative-metadata",
             "#{plan.target_reps} reps"
           )

    view |> element("#home-alternative-plan-#{plan.id}-select") |> render_click()
    assert has_element?(view, "#home-summary", plan.name)
    assert has_element?(view, "#home-alternatives-panel[hidden]")
    assert Repo.aggregate(WorkoutSession, :count) == 0
    open_swap(view)
    view |> element("#home-tab-videos") |> render_click()

    assert has_element?(
             view,
             "#home-alternative-video-#{video.id} .home-alternative-metadata",
             "20 min · 60 reps"
           )

    # A video without a known count has no level, so it is not listed.
    refute has_element?(view, "#home-alternative-video-#{unknown.id}")
    assert has_element?(view, "#home-summary", plan.name)
    view |> element("#home-alternative-video-#{video.id}-select") |> render_click()
    session = Workouts.current_started_session(Scope.for_user(user))
    assert session.workout_video_id == video.id
    assert_redirect(view, ~p"/videos/#{video.id}/session/#{session.id}")
  end

  test "chooser close hides the client-opened dialog and returns focus to Home", %{
    conn: conn,
    user: user
  } do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    open_swap(view)
    doc = render(view) |> LazyHTML.from_fragment()

    [close] = doc |> LazyHTML.query("#home-chooser-close") |> LazyHTML.attribute("phx-click")

    assert [
             ["set_attr", %{"attr" => ["hidden", ""], "to" => "#home-alternatives-panel"}],
             ["remove_attr", %{"attr" => "inert"}],
             ["focus", %{"to" => "#home-summary"}],
             ["push", %{"event" => "close_chooser"}]
           ] = Jason.decode!(close)
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

    render_click(view, "start_workout", %{"client_session_id" => Ecto.UUID.generate()})
    assert Repo.aggregate(WorkoutSession, :count) == 0

    render_click(view, "start_workout", %{"client_session_id" => client_session_id})

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
    assert has_element?(view, "#home-history-period-twelve_weeks[aria-pressed=true]")
    # A point selects its session in the list: the row has the numbers.
    view |> element("#home-history-point-#{saved.id}") |> render_click()
    assert has_element?(view, "#home-history-inspect-#{saved.id}[aria-pressed=true]")

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

  test "failed deletion says so in place and the session can still close", %{
    conn: conn,
    user: user
  } do
    saved = complete_history(user, DateTime.utc_now(:second), 1_200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    view |> element("#home-history-delete-#{saved.id}") |> render_click()
    Repo.delete!(saved)
    view |> element("#home-history-delete-#{saved.id}") |> render_click()
    # The session is gone, so its row is too; Progress says so at the top.
    assert has_element?(view, "#home-history-error[role=status]", "Couldn’t delete this session")
    refute has_element?(view, "#home-history-delete-#{saved.id}")
  end

  test "the day grid shows each day's type and minutes above the chart", %{
    conn: conn,
    user: user
  } do
    saved = complete_history(user, DateTime.utc_now(:second), 1_200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)
    day = Date.to_iso8601(DateTime.to_date(saved.completed_at))

    assert has_element?(
             view,
             "#home-history-day-#{day}[data-minutes='20'][role=img][aria-label$='Six-count, 20 min']"
           )

    # The grid comes before the chart.
    assert has_element?(view, "#home-history-weekly + #home-history-reps #home-history-trend")
  end

  test "History deletion requires confirmation and refreshes owned progress", %{
    conn: conn,
    user: user
  } do
    saved = complete_history(user, DateTime.utc_now(:second), 4_800)
    foreign = complete_history(user_fixture(), DateTime.utc_now(:second), 1200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)

    trash = "#home-history-delete-#{saved.id}"
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    # The first tap on the trash arms it; tapping the row again lets go of it.
    view |> element(trash) |> render_click()

    assert has_element?(
             view,
             "#{trash}.home-history-session-delete-armed[aria-label='Confirm delete session']"
           )

    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    assert Repo.reload!(saved) == saved
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    refute has_element?(view, "#{trash}.home-history-session-delete-armed")
    view |> element(trash) |> render_click()
    view |> element(trash) |> render_click()
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

    # Resuming starts like a new workout, so its camera and warmup can be changed here.
    for id <- ~w[home-start-camera home-start-warmup] do
      assert has_element?(
               view,
               ".home-resume-actions ##{id}[phx-hook=HomeStartChoice][phx-update=ignore]"
             )
    end

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
    assert has_element?(view, "#home-action[aria-label='Start workout'] .hero-play-solid")
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "expansion preserves DOM for both transition directions", %{conn: conn, user: user} do
    recommendation_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-expansion[data-open='false']")
    assert has_element?(view, "#home-expansion-content[inert][aria-hidden='true']")
    refute has_element?(view, "#desktop-home-nav")
    # Switch opens a dialog outside the collapsed, inert content.
    open_swap(view)
    assert has_element?(view, "#home-alternatives-panel[role=dialog]:not([hidden])")
    refute has_element?(view, "#home-expansion-content[inert] #home-alternatives-panel")
    view |> element("#home-chooser-close") |> render_click()
    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-expansion[data-open='true']")
    refute has_element?(view, "#home-expansion-content[inert]")

    assert has_element?(
             view,
             "#home-action[type=button][aria-label='Start workout'] .hero-play-solid"
           )

    view |> element("#home-summary") |> render_click()
    assert has_element?(view, "#home-expansion-content[inert]")
    assert has_element?(view, "#home-inspection")
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "History range changes the chart and its sessions together, not the day grid", %{
    user: user
  } do
    now = ~U[2026-09-23 12:00:00Z]
    recent = complete_history(user, now, 1200)
    previous_year = complete_history(user, ~U[2025-08-01 12:00:00Z], 1200)
    socket = mounted_socket(user) |> Phoenix.Component.assign(home_now: fn -> now end)
    {:noreply, recent_view} = workspace_screen(socket, :history)
    # The chart starts at the first week with training: only this week in the last 12.
    assert length(recent_view.assigns.history_weeks) == 1
    assert recent.id in Enum.map(recent_view.assigns.history_points.six_count, & &1.id)
    refute previous_year.id in Enum.map(recent_view.assigns.history_points.six_count, & &1.id)

    {:noreply, year_view} =
      HomeLive.handle_event("history_period", %{"period" => "year"}, recent_view)

    assert length(year_view.assigns.history_weeks) == 1
    assert length(year_view.assigns.history_points.six_count) == 1

    {:noreply, all_view} =
      HomeLive.handle_event("history_period", %{"period" => "all"}, year_view)

    assert length(all_view.assigns.history_weeks) > 52
    # The day grid holds its recent weeks whatever the window.
    assert all_view.assigns.history_grid_weeks == recent_view.assigns.history_grid_weeks
    assert length(all_view.assigns.history_points.six_count) == 2
  end

  test "History opening moves focus to its heading and closing restores Home and focus",
       %{
         conn: conn,
         user: user
       } do
    complete_history(user, DateTime.add(DateTime.utc_now(:second), -90 * 86400), 1200)
    {:ok, view, _} = live(conn, ~p"/")
    before = :sys.get_state(view.pid).socket

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
    assert has_element?(view, "#home-history-inspect-#{oldest.id}[aria-pressed=true]")
    view |> element("#home-history-point-#{newest.id}") |> render_click()

    for expected_count <- [11, 12] do
      assert has_element?(
               view,
               "#home-history-more[aria-label='Load more sessions'] .hero-chevron-down"
             )

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
      assert has_element?(view, "#home-history-inspect-#{newest.id}[aria-pressed=true]")
    end

    refute has_element?(view, "#home-history-more")
    refute has_element?(view, "#home-history-pagination-terminal")
    view |> element("#home-history-inspect-#{oldest.id}") |> render_click()
    refute has_element?(view, "#home-history-inspect-#{oldest.id}[aria-pressed=true]")
    refute has_element?(view, "#home-history-inspect-#{newest.id}[aria-pressed=true]")
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
    refute has_element?(view, "#home-history")
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
    # The mood you just chose is not echoed back.
    refute has_element?(view, "#home-today-mood")

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

    render_click(view, "start_workout", %{"client_session_id" => Ecto.UUID.generate()})

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

    render_click(view, "start_workout", %{"client_session_id" => Ecto.UUID.generate()})

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

  defp assert_workspace_unchanged(before, after_socket) do
    keys = [
      :home_selection,
      :start_client_session_id,
      :instruction,
      :adjustment_form,
      :expanded?,
      :expanded_groups,
      :active_tab,
      :busy?,
      :update_id,
      :started_session,
      :slot
    ]

    assert Map.take(before.assigns, keys) == Map.take(after_socket.assigns, keys)
  end

  test "a session's row carries its tags", %{conn: conn, user: user} do
    completed_at = DateTime.utc_now(:second)
    tagged = complete_history(user, completed_at, 1_200, tags: "heat, low_energy")
    plain = complete_history(user, DateTime.add(completed_at, -1, :second), 1_200)
    {:ok, view, _} = live(conn, ~p"/")
    view = history_route(conn, view)
    view |> element("#home-history-density-sessions") |> render_click()

    assert has_element?(
             view,
             "#home-history-inspect-#{tagged.id} .home-history-session-tag",
             "Heat"
           )

    assert has_element?(
             view,
             "#home-history-inspect-#{tagged.id} .home-history-session-tag",
             "Low energy"
           )

    refute has_element?(view, "#home-history-inspect-#{plain.id} .home-history-session-tag")
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
  # Two sets of five at the wizard's default pace; the rest between them is computed.
end
