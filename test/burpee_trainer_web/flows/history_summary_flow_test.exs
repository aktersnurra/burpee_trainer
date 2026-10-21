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

  test "the coach's line reads on Progress; talking to the coach is on Home", %{
    conn: conn,
    user: user
  } do
    goal_fixture(user, %{burpee_count_target: 150})
    free_form_session_fixture(user, %{duration_sec_actual: 1_500})
    summary_fixture(user, "Best so far 25 of 150 reps.", "Six-count held at 25 reps.")

    {:ok, view, _} = live(conn, ~p"/progress")
    header = text(view, "#history-header")
    assert has_element?(view, "#history-level", "1A")
    # The week's minutes live in the progress row above, not again in the header.
    refute header =~ "min this week"
    assert has_element?(view, "#history-progress #home-week-duration", "25 / 80 min")
    # Each type's goal reads in its own gauge.
    assert has_element?(view, "#progress-gauge-six_count[data-kind=goal]", "of 150 by")
    assert has_element?(view, "#progress-gauge-navy_seal[data-kind=none]", "No sessions yet")
    # Progress reads the coach's look back; the note about what's next is for Home.
    assert has_element?(view, "#history-header p#history-coach-summary", "Six-count held")
    refute has_element?(view, "#history-coach-summary", "Best so far")
    refute has_element?(view, "#home-coach-panel, a[href^='/coach']")
  end

  test "each burpee type has its own gauge, and both share one chart", %{
    conn: conn,
    user: user
  } do
    goal_fixture(user, %{burpee_count_target: 150})

    goal_fixture(user, %{
      burpee_type: "navy_seal",
      burpee_count_target: 60,
      date_target: Date.to_iso8601(Date.add(Date.utc_today(), 89))
    })

    free_form_session_fixture(user, %{duration_sec_actual: 1_200, burpee_count_actual: 140})
    # Longer than 20 minutes, so it does not count toward the goal.
    free_form_session_fixture(user, %{duration_sec_actual: 1_500, burpee_count_actual: 149})

    free_form_session_fixture(user, %{
      burpee_type: "navy_seal",
      duration_sec_actual: 1_200,
      burpee_count_actual: 30
    })

    {:ok, view, _} = live(conn, ~p"/progress")
    assert has_element?(view, "#progress-gauge-six_count .progress-gauge-number", "140")
    assert has_element?(view, "#progress-gauge-navy_seal .progress-gauge-number", "30")
    assert has_element?(view, "#progress-gauge-navy_seal", "of 60 by")
    # One chart: six-count on the left axis, Navy SEAL on the right, each topped by its goal.
    assert has_element?(view, "#home-history-trend-axis-left.progress-key-six-count", "150")
    assert has_element?(view, "#home-history-trend-axis-right.progress-key-navy-seal", "60")
    assert has_element?(view, "#home-history-trend .home-history-goal-line")
  end

  test "a goal on a rising line shows when it will be reached", %{conn: conn, user: user} do
    goal_fixture(user, %{
      burpee_count_target: 150,
      date_target: Date.to_iso8601(Date.add(Date.utc_today(), 60))
    })

    for {weeks_ago, reps} <- [{3, 100}, {2, 110}, {1, 120}, {0, 130}] do
      completed_at =
        DateTime.add(DateTime.utc_now(:second), -7 * weeks_ago * 86_400 - 60, :second)

      free_form_session_fixture(user, %{
        duration_sec_actual: 1_200,
        burpee_count_actual: reps,
        completed_at: completed_at
      })
    end

    {:ok, view, _} = live(conn, ~p"/progress")
    assert has_element?(view, "#progress-gauge-six_count .progress-course-on", "On course for")
  end

  test "with no goal, the best shows and the next goal is one tap away", %{conn: conn, user: user} do
    for reps <- [110, 130, 120],
        do:
          free_form_session_fixture(user, %{duration_sec_actual: 1_200, burpee_count_actual: reps})

    {:ok, view, _} = live(conn, ~p"/progress")

    assert has_element?(view, "#progress-gauge-six_count[data-kind=best]", "Best in 20 min")
    assert has_element?(view, "#progress-set-goal-six_count .hero-plus")
    assert has_element?(view, "#progress-set-goal-six_count", "150 by")
    view |> element("#progress-set-goal-six_count") |> render_click()
    assert has_element?(view, "#progress-gauge-six_count[data-kind=goal]", "of 150 by")

    assert [%{status: :active, burpee_count_target: 150}] =
             BurpeeTrainer.Goals.list(Scope.for_user(user))
  end

  test "after the first workout, its result is the starting point", %{conn: conn, user: user} do
    free_form_session_fixture(user, %{duration_sec_actual: 1_200, burpee_count_actual: 110})
    {:ok, view, _} = live(conn, ~p"/progress")

    assert has_element?(
             view,
             "#progress-gauge-six_count[data-kind=first] .progress-gauge-number",
             "110"
           )

    assert has_element?(view, "#progress-gauge-six_count", "First session")
    refute has_element?(view, "#progress-set-goal-six_count")
  end

  test "the streak counts weeks in a row at the target, this one once it is met", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/progress")
    refute has_element?(view, "#history-streak")

    free_form_session_fixture(user, %{duration_sec_actual: 4_800})
    {:ok, view, _} = live(conn, ~p"/progress")

    assert has_element?(
             view,
             "#history-streak[aria-label='1 week in a row at the weekly target'] .hero-fire"
           )
  end

  test "the page is Progress, and old History links land on it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/progress")
    # Progress is titled by your level; it is still named Progress for screen readers.
    assert has_element?(view, "#home-history-heading[aria-label^='Progress, Level']", "Level")
    assert {:error, {:live_redirect, %{to: "/progress"}}} = live(conn, "/history")
  end

  test "the week grid names weeks that hit the target, and none when none have", %{
    conn: conn,
    user: user
  } do
    free_form_session_fixture(user, %{duration_sec_actual: 1_500})
    {:ok, view, _} = live(conn, ~p"/progress")
    refute has_element?(view, "#home-history-week-count")
    refute has_element?(view, ".home-history-week-current, .home-history-week-key")
    assert has_element?(view, "#history-level", "Level 1A")
  end

  test "with nothing to summarize, neither Progress nor Home shows the coach", %{conn: conn} do
    {:ok, home, _} = live(conn, ~p"/")
    refute has_element?(home, "#home-coach-panel")
    {:ok, view, _} = live(conn, ~p"/progress")
    refute has_element?(view, "#history-coach-summary")
  end

  test "a refreshing summary shows the loader in the coach's line until the new one arrives", %{
    conn: conn,
    user: user
  } do
    free_form_session_fixture(user)
    old = summary_fixture(user, "Last week's note.", "Last week's summary.")

    Repo.update_all(from(s in Summary, where: s.id == ^old.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -8, :day)]
    )

    {:ok, view, _} = live(conn, ~p"/progress")
    assert has_element?(view, "#history-coach-summary [role=status]", "Updating your summary")
    assert has_element?(view, "#history-coach-summary img.coach-summary-loader")

    fresh = summary_fixture(user, "This week's note.", "This week's summary.")
    Summary.broadcast(Scope.for_user(user), fresh)
    assert has_element?(view, "#history-coach-summary", "This week's summary.")
    refute has_element?(view, "#history-coach-summary [role=status]")
  end

  test "the coach section: its word first, this week, the conversation, message, goals", %{
    conn: conn,
    user: user
  } do
    summary_fixture(user)
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})
    {:ok, view, _} = live(conn, ~p"/")
    html = render(view)

    positions =
      for id <-
            ~w[home-coach-note home-coach-week home-coach-message-form home-coach-reply home-coach-goals] do
        {index, _} = :binary.match(html, ~s(id="#{id}"))
        index
      end

    assert positions == Enum.sort(positions)
    # The field is named by its placeholder; the label is for screen readers only.
    assert has_element?(
             view,
             "label[for='home-coach-message-text']",
             "Message the coach"
           )

    assert has_element?(view, "#home-coach-message-text[placeholder='Message the coach']")

    assert has_element?(
             view,
             "#home-coach-message-form #home-coach-message-send[aria-label=Send]"
           )

    # The week's window: today's session done, the rest of the 80 minutes left.
    assert has_element?(
             view,
             "#home-coach-panel #home-coach-week [data-status=done]",
             "Six-count"
           )

    assert has_element?(view, "#home-coach-panel #home-coach-week [data-status=left]")
    # A section of the page, not a card, and the week in Progress's rows.
    refute has_element?(view, ".coach-card, .coach-card-face")
    assert has_element?(view, "#home-coach-week .coach-week-type.progress-key-six-count")
    # No notebook: the coach keeps its memory itself.
    refute has_element?(view, "#home-coach-notebook, #home-coach-flip")

    busy =
      render_component(&HomeCoachComponents.panel/1,
        state: %{:sys.get_state(view.pid).socket.assigns | coach_busy?: true}
      )

    assert busy =~ "Sending to the coach"
  end

  test "what the coach noted or forgot reads in the thread, after the exchange that caused it",
       %{conn: conn, user: user} do
    scope = Scope.for_user(user)
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})

    {:ok, _} =
      BurpeeTrainer.Coach.Memory.apply_ops(scope, [%{"op" => "add", "text" => "Trains at 7:00"}])

    {:ok, _} = BurpeeTrainer.Coach.Exchange.record(scope, "I train evenings now", "18:00 then.")
    [old] = BurpeeTrainer.Coach.Memory.list(scope)

    {:ok, _} =
      BurpeeTrainer.Coach.Memory.apply_ops(scope, [
        %{"op" => "replace", "id" => old.id, "text" => "Trains at 18:00"}
      ])

    {:ok, view, _} = live(conn, ~p"/")
    html = render(view)
    {said, _} = :binary.match(html, "I train evenings now")
    {noted, _} = :binary.match(html, "Noted: Trains at 18:00")
    {forgot, _} = :binary.match(html, "Forgot: Trains at 7:00")
    assert said < noted and said < forgot
    assert has_element?(view, "#home-coach-thread .coach-memory[data-kind=noted] .hero-bookmark")
  end

  defp text(view, selector),
    do:
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
end
