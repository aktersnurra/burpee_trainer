defmodule BurpeeTrainerWeb.Flows.CoachConversationFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Accounts.Scope

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    %{conn: init_test_session(conn, %{user_id: user.id}), scope: Scope.for_user(user)}
  end

  test "actual unsent message survives Coach Home History patches in the same process", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/coach")
    pid = view.pid

    view
    |> form("#home-coach-message-form", coach_message: %{text: "UNSENT morning preference"})
    |> render_change()

    view |> element("#home-coach-back") |> render_click()
    assert_patch(view, "/")
    render_patch(view, ~p"/history")
    view |> element("#history-coach-open") |> render_click()
    assert_patch(view, "/coach?from=history")
    assert view.pid == pid
    assert has_element?(view, "#home-coach-message-text", "UNSENT morning preference")
    view |> element("#home-coach-back") |> render_click()
    assert_patch(view, "/history")
    view |> element("#history-coach-open") |> render_click()
    assert has_element?(view, "#home-coach-message-text", "UNSENT morning preference")
  end

  test "disabled provider retains submitted text and reports unavailability", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/coach")

    view
    |> form("#home-coach-message-form", coach_message: %{text: "Please note mornings"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#home-coach-message-text", "Please note mornings")
    assert has_element?(view, "#home-coach-reply", "Coach unavailable")
  end

  test "goal confirmation and notebook edit use scoped effects", %{conn: conn, scope: scope} do
    assert {:ok, %{"goal_id" => id}} =
             BurpeeTrainer.Coach.Tools.ProposeGoal.call(
               scope,
               %{
                 "burpee_type" => "six_count",
                 "burpee_count_target" => 150,
                 "duration_sec_target" => 1200,
                 "date_target" => Date.to_iso8601(Date.add(Date.utc_today(), 42))
               },
               %{}
             )

    {:ok, view, _} = live(conn, ~p"/coach")
    assert has_element?(view, "#home-coach-goal-#{id}[data-status=proposed]")
    view |> element("#home-coach-goal-#{id}-confirm") |> render_click()
    assert has_element?(view, "#home-coach-goal-#{id}[data-status=active]")
    assert summary_jobs() == 1
    BurpeeTrainer.Repo.delete_all(Oban.Job)

    view
    |> form("#home-coach-notebook-form", coach_notebook: %{text: "Owner note"})
    |> render_submit()

    assert BurpeeTrainer.Coach.Notebook.get(scope).body == "Owner note"
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
      "duration_sec_target" => 1200,
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
    {:ok, view, _} = live(conn, ~p"/coach")
    Req.Test.allow(__MODULE__, self(), view.pid)

    view
    |> form("#home-coach-message-form",
      coach_message: %{text: "Set a goal of 150 reps in 20 minutes in six weeks"}
    )
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#home-coach-reply", "Goal proposed.")
    assert [goal] = BurpeeTrainer.Goals.list(scope)
    assert goal.status == :proposed
    assert has_element?(view, "#home-coach-goal-#{goal.id}[data-status=proposed]")
    view |> element("#home-coach-goal-#{goal.id}-confirm") |> render_click()
    assert has_element?(view, "#home-coach-goal-#{goal.id}[data-status=active]")
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
