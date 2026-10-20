defmodule BurpeeTrainerWeb.Flows.CoachConversationFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Accounts.Scope

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    # The coach speaks on Home once today's training is done.
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})
    %{conn: init_test_session(conn, %{user_id: user.id}), scope: Scope.for_user(user)}
  end

  test "an unsent message survives a visit to Progress in the same process", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    pid = view.pid

    assert has_element?(
             view,
             "#home-done-today[data-expanded=false] ~ #home-done-expansion #home-coach-panel"
           )

    view
    |> form("#home-coach-message-form", coach_message: %{text: "UNSENT morning preference"})
    |> render_change()

    view |> element("#home-history-toggle") |> render_click()
    assert_patch(view, "/progress")
    refute has_element?(view, "#home-coach-panel")
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    assert view.pid == pid
    assert has_element?(view, "#home-coach-message-text", "UNSENT morning preference")
  end

  test "disabled provider retains submitted text and reports unavailability", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("#home-coach-message-form", coach_message: %{text: "Please note mornings"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#home-coach-message-text", "Please note mornings")
    assert has_element?(view, "#home-coach-reply", "Coach unavailable")
  end

  test "the pills are what the coach expects you to say next", %{conn: conn, scope: scope} do
    {:ok, _} =
      BurpeeTrainer.Coach.Summary.store(scope, %{
        text: "Protect Thursday.",
        metric_ids: [],
        source: :llm,
        suggestions: ["Why Thursday?"]
      })

    {:ok, view, _} = live(conn, ~p"/")
    # Before any exchange, the note's suggestions.
    assert has_element?(view, ".coach-quick-replies button", "Why Thursday?")

    {:ok, _} =
      BurpeeTrainer.Coach.Exchange.record(scope, "Why Thursday?", "It is your longest day.", [
        "Move it to Friday"
      ])

    {:ok, view, _} = live(conn, ~p"/")
    # After an exchange, the reply's suggestions.
    assert has_element?(view, ".coach-quick-replies button", "Move it to Friday")
    refute has_element?(view, ".coach-quick-replies button", "Why Thursday?")
  end

  test "the week's conversation reads in order, oldest first",
       %{conn: conn, scope: scope} do
    {:ok, first} = BurpeeTrainer.Coach.Exchange.record(scope, "Can Thursday be mornings?", "Yes.")
    {:ok, second} = BurpeeTrainer.Coach.Exchange.record(scope, "Make it shorter", "15 minutes.")
    {:ok, view, _} = live(conn, ~p"/")

    html = render(view)
    {a, _} = :binary.match(html, "home-coach-exchange-#{first.id}")
    {b, _} = :binary.match(html, "home-coach-exchange-#{second.id}")
    assert a < b

    assert :sys.get_state(view.pid).socket.assigns.coach_thread
           |> Enum.map(&{&1.message, &1.reply}) ==
             [{"Can Thursday be mornings?", "Yes."}, {"Make it shorter", "15 minutes."}]
  end

  test "a one-tap reply sends its words to the coach", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-coach-quick-harder") |> render_click()
    render_async(view)
    # No provider in tests: the send happened and the coach says it is unavailable.
    assert has_element?(view, "#home-coach-reply", "Coach unavailable")
    # There is no notebook to edit: the coach keeps its memory itself.
    refute has_element?(view, "#home-coach-notebook")
  end

  test "goal confirmation is scoped and admits a new summary", %{conn: conn, scope: scope} do
    assert {:ok, %{"goal_id" => id}} =
             BurpeeTrainer.Coach.Tools.ProposeGoal.call(
               scope,
               %{
                 "burpee_type" => "six_count",
                 "burpee_count_target" => 150,
                 "date_target" => Date.to_iso8601(Date.add(Date.utc_today(), 42))
               },
               %{}
             )

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-coach-goal-#{id}[data-status=proposed]")
    view |> element("#home-coach-goal-#{id}-confirm") |> render_click()
    # A confirmed goal leaves Coach's list for the header above it, so it reads once.
    refute has_element?(view, "#home-coach-goal-#{id}")
    # A confirmed goal leads Progress.
    render_patch(view, ~p"/progress")
    assert has_element?(view, "#progress-gauge-six_count[data-kind=goal]", "of 150")
    render_patch(view, ~p"/")
    assert summary_jobs() == 1
  end

  test "real provider tool conversation proposes a goal, replies, then confirms in the same screen",
       %{conn: conn, scope: scope} do
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)
    previous_req = Req.default_options()

    on_exit(fn ->
      Application.put_env(:burpee_trainer, :llm_provider, previous_provider)
      Req.default_options(previous_req)
    end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "k",
      model: "m"
    )

    args = %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 150,
      "date_target" => Date.to_iso8601(Date.add(Date.utc_today(), 42))
    }

    replies =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "tool_calls" => [
                       %{
                         "id" => "goal",
                         "function" => %{
                           "name" => "propose_goal",
                           "arguments" => Jason.encode!(args)
                         }
                       }
                     ]
                   }
                 }
               ]
             },
             %{
               "choices" => [
                 %{"message" => %{"content" => Jason.encode!(%{"reply" => "Goal proposed."})}}
               ]
             }
           ]
         end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, Agent.get_and_update(replies, fn [head | tail] -> {head, tail} end))
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    {:ok, view, _} = live(conn, ~p"/")
    Req.Test.allow(__MODULE__, self(), view.pid)

    view
    |> form("#home-coach-message-form",
      coach_message: %{text: "Set a goal of 150 reps in 20 minutes in six weeks"}
    )
    |> render_submit()

    render_async(view)
    # The exchange stays: your message and the reply, after a reload too.
    assert has_element?(
             view,
             "#home-coach-thread .coach-exchange",
             "Set a goal of 150 reps in 20 minutes"
           )

    assert has_element?(view, "#home-coach-thread .coach-exchange", "Goal proposed.")
    {:ok, reloaded, _} = live(conn, ~p"/")
    assert has_element?(reloaded, "#home-coach-thread .coach-exchange", "Goal proposed.")
    assert [goal] = BurpeeTrainer.Goals.list(scope)
    assert goal.status == :proposed
    assert has_element?(view, "#home-coach-goal-#{goal.id}[data-status=proposed]")
    view |> element("#home-coach-goal-#{goal.id}-confirm") |> render_click()
    refute has_element?(view, "#home-coach-goal-#{goal.id}")
    # A confirmed goal leads Progress.
    render_patch(view, ~p"/progress")
    assert has_element?(view, "#progress-gauge-six_count[data-kind=goal]", "of 150")
    render_patch(view, ~p"/")
    assert BurpeeTrainer.Repo.reload!(goal).status == :active
  end

  defp summary_jobs do
    import Ecto.Query

    BurpeeTrainer.Repo.aggregate(
      from(job in Oban.Job, where: job.worker == "BurpeeTrainer.Coach.SummaryJob"),
      :count
    )
  end
end
