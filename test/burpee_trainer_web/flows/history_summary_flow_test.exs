defmodule BurpeeTrainerWeb.Flows.HistorySummaryFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Summary
  alias BurpeeTrainerWeb.HomeCoachComponents

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    %{conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "the summary heads History and is the way into Coach and back", %{conn: conn, user: user} do
    goal_fixture(user, %{burpee_count_target: 150, duration_sec_target: 1200})
    free_form_session_fixture(user, %{duration_sec_actual: 1_500})
    summary_fixture(user, "Best so far 25 of 150 reps.")

    {:ok, view, _} = live(conn, ~p"/history")
    header = text(view, "#history-header")
    assert header =~ "Level 1A"
    # The week's minutes live in the progress row above, not again in the header.
    refute header =~ "min this week"
    assert has_element?(view, "#history-progress #home-week-duration", "25 / 80 min")
    assert header =~ "150 reps in 20 min"

    assert has_element?(
             view,
             "#history-header a#history-coach-summary[href='/coach']",
             "Best so far"
           )

    pid = view.pid

    # Coach opens inside History, under the summary, like the workout card on Home.
    view |> element("#history-coach-summary") |> render_click()
    assert_patch(view, "/coach")
    assert view.pid == pid
    assert has_element?(view, "#history-page #history-header #home-coach-panel")
    assert has_element?(view, "#history-coach-summary[aria-expanded=true]", "Best so far")
    refute has_element?(view, "#home-coach-back, #home-coach-heading, #home-coach-summary")
    # Coach unfolds under its summary and folds away before History closes it.
    assert has_element?(view, "#history-coach-expansion #home-coach-panel")
    assert view |> element("#history-coach-summary") |> render() =~ "history-coach-closing"
    # The active goal reads once, in the header, not again in Coach's list.
    refute has_element?(view, "#home-coach-goals [data-status=active]")

    view |> element("#history-coach-summary") |> render_click()
    assert_patch(view, "/history")
    refute has_element?(view, "#home-coach-panel")
    assert has_element?(view, "#history-coach-summary[aria-expanded=false]")
  end

  test "with nothing to summarize, History invites the owner to the coach and Home does not", %{
    conn: conn
  } do
    {:ok, home, _} = live(conn, ~p"/")
    refute has_element?(home, "a[href^='/coach']")

    {:ok, view, _} = live(conn, ~p"/history")

    assert has_element?(
             view,
             "a#history-coach-summary[href='/coach']",
             "Tell the coach what you're training for"
           )

    # It reads as a way in, not a caption.
    assert has_element?(view, "#history-coach-summary .history-coach-summary-arrow")

    view |> element("#history-coach-summary") |> render_click()
    assert_patch(view, "/coach")
    assert has_element?(view, "#home-coach-panel")
  end

  test "a refreshing summary shows the loader inside the link until the new one arrives", %{
    conn: conn,
    user: user
  } do
    free_form_session_fixture(user)
    old = summary_fixture(user, "Last week's summary.")

    Repo.update_all(from(s in Summary, where: s.id == ^old.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -8, :day)]
    )

    {:ok, view, _} = live(conn, ~p"/history")
    assert has_element?(view, "#history-coach-summary [role=status]", "Updating your summary")
    assert has_element?(view, "#history-coach-summary img.coach-summary-loader")

    fresh = summary_fixture(user, "This week's summary.")
    Summary.broadcast(Scope.for_user(user), fresh)
    assert has_element?(view, "#history-coach-summary", "This week's summary.")
    refute has_element?(view, "#history-coach-summary [role=status]")
  end

  test "a Coach link opens History with Coach open, and Escape closes it", %{conn: conn} do
    for path <- ["/coach", "/coach?from=home", "/coach?from=//evil.example"] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#history-page #home-coach-panel")
      view |> element("#home-coach-panel") |> render_keydown(%{"key" => "Escape"})
      assert_patch(view, "/history")
      assert focus_target(view, "#home-history-heading") == "#history-coach-summary"
    end
  end

  test "Coach reads top to bottom under its summary: goals, message, reply, notebook", %{
    conn: conn,
    user: user
  } do
    summary_fixture(user)
    {:ok, view, _} = live(conn, ~p"/coach")
    html = render(view)

    positions =
      for id <-
            ~w[history-coach-summary home-coach-goals home-coach-message-form home-coach-reply home-coach-notebook] do
        {index, _} = :binary.match(html, ~s(id="#{id}"))
        index
      end

    assert positions == Enum.sort(positions)
    assert has_element?(view, "label[for='home-coach-message-text']", "Tell the coach")
    # Coach's fields and actions are the New form's: underlined rows and one filled action.
    assert has_element?(view, "#home-coach-message-form.home-authoring-form")
    assert has_element?(view, "#home-coach-message-text.home-authoring-input")
    assert has_element?(view, "#home-coach-message-send.home-primary-action")
    assert has_element?(view, "#home-coach-notebook-save.home-primary-action")
    assert has_element?(view, "#home-coach-notebook-clear.home-text-action")

    assert has_element?(
             view,
             "details#home-coach-notebook:not([open]) summary",
             "What the coach knows"
           )

    assert has_element?(view, "#home-coach-notebook-toggle .history-coach-memory-chevron")
    assert has_element?(view, "#home-coach-notebook #home-coach-notebook-save")
    assert has_element?(view, "#home-coach-notebook #home-coach-notebook-clear")

    busy =
      render_component(&HomeCoachComponents.panel/1,
        state: %{:sys.get_state(view.pid).socket.assigns | coach_busy?: true}
      )

    assert busy =~ "Sending to the coach"
  end

  defp text(view, selector),
    do:
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()

  defp focus_target(view, selector) do
    [commands] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("phx-mounted")

    [["focus", %{"to" => target}]] = Jason.decode!(commands)
    target
  end
end
