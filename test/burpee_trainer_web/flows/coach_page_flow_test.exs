defmodule BurpeeTrainerWeb.Flows.CoachPageFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Memory, SummaryJob}
  alias BurpeeTrainer.Repo

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})
    summary_fixture(user, "Two sessions left; keep Thursday easy.", "Six-count held at 25 reps.")
    %{conn: init_test_session(conn, %{user_id: user.id}), user: user, scope: Scope.for_user(user)}
  end

  test "the Coach page: the week, then the chat opened by the coach's note, and the box", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/coach")

    assert has_element?(view, "#coach-page h1", "Coach")
    assert has_element?(view, "#coach-page #home-coach-week [data-status=done]", "Six-count")
    assert has_element?(view, "#coach-page #home-coach-note", "Two sessions left")
    assert has_element?(view, "#coach-page #home-coach-message-form")
    assert has_element?(view, "#coach-back[href='/'][aria-label=Back]")
  end

  test "without the app's coach, /coach goes Home", %{conn: conn, user: user} do
    user |> Ecto.Changeset.change(coach_enabled: false) |> Repo.update!()

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/coach")
  end

  test "Home's bookmark opens the Coach page, and Back returns Home", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#coach-memory-open")

    view |> element("#home-coach-open") |> render_click()
    assert_patch(view, ~p"/coach")
    assert has_element?(view, "#coach-page")

    view |> element("#coach-back") |> render_click()
    assert_patch(view, ~p"/")
    assert has_element?(view, "#home-coach-panel")
  end

  test "from Progress the look back is the first message, and Back returns to Progress", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/progress")

    view |> element("#history-look-back") |> render_click()
    assert_patch(view, ~p"/coach?from=progress")
    assert has_element?(view, "#home-coach-note", "Six-count held at 25 reps.")
    refute has_element?(view, "#home-coach-note", "Two sessions left")

    view |> element("#coach-back[href='/progress']") |> render_click()
    assert_patch(view, ~p"/progress")
    assert has_element?(view, "#history-look-back")
  end

  test "with nothing to look back on, Progress still leads to the coach", %{
    conn: conn,
    user: user
  } do
    summary_fixture(user, "Two sessions left; keep Thursday easy.", nil)
    {:ok, view, _} = live(conn, ~p"/progress")

    refute has_element?(view, "#history-coach-summary")
    view |> element("#history-look-back") |> render_click()
    assert_patch(view, ~p"/coach?from=progress")
    assert has_element?(view, "#coach-page")
  end

  test "the bookmark opens what the coach remembers by part, read-only, and Escape closes it",
       %{conn: conn, scope: scope} do
    {:ok, _} = Memory.write(scope, "user", [%{"action" => "add", "content" => "Trains at 7:00"}])
    {:ok, _} = Memory.write(scope, "user", [%{"action" => "add", "content" => "Left knee sore"}])

    {:ok, _} =
      Memory.write(scope, "user", [
        %{"action" => "patch", "old_text" => "Left knee sore", "content" => "Left knee is fine"}
      ])

    {:ok, view, _} = live(conn, ~p"/coach")
    refute has_element?(view, "#coach-memory")

    view |> element("#coach-memory-open") |> render_click()
    assert has_element?(view, "#coach-memory-open[aria-expanded=true]")
    assert has_element?(view, "#coach-memory[role=dialog][aria-modal=true]")
    assert has_element?(view, "#coach-memory #coach-memory-title", "What I remember")
    assert has_element?(view, "#coach-memory-user", "About you")
    assert has_element?(view, "#coach-memory-user [role=meter][aria-valuenow]")
    assert has_element?(view, "#coach-memory-memory", "Coaching notes")
    assert has_element?(view, "#coach-memory-memory", "Nothing yet.")
    assert has_element?(view, "#coach-memory", "To change a line, tell the coach.")

    # The line the coach rewrote this week is marked; the one it only added is not.
    [kept, patched] = Memory.list(scope)
    assert has_element?(view, "#coach-memory-entry-#{patched.id}[data-changed=true]")
    assert has_element?(view, "#coach-memory-entry-#{kept.id}[data-changed=false]")

    # A line changes by telling the coach; there is nothing to remove by hand.
    refute has_element?(view, "#coach-memory button[id^=coach-memory-forget]")

    view |> element("#coach-memory") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#coach-memory")
    assert has_element?(view, "#coach-memory-open[aria-expanded=false]")
  end

  test "leaving the Coach page after the coach wrote to its memory writes the summary again", %{
    conn: conn
  } do
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

    remember = %{
      "target" => "user",
      "operations" => [%{"action" => "add", "content" => "Trains at 7:00"}]
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
                         "id" => "m",
                         "function" => %{
                           "name" => "memory",
                           "arguments" => Jason.encode!(remember)
                         }
                       }
                     ]
                   }
                 }
               ]
             },
             %{
               "choices" => [
                 %{"message" => %{"content" => Jason.encode!(%{"reply" => "Mornings it is."})}}
               ]
             }
           ]
         end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      BurpeeTrainer.ProviderStream.reply(
        conn,
        Agent.get_and_update(replies, fn [head | tail] -> {head, tail} end)
      )
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    {:ok, view, _} = live(conn, ~p"/coach?from=progress")
    Req.Test.allow(__MODULE__, self(), view.pid)

    # Nothing changed: leaving writes nothing.
    view |> element("#coach-back") |> render_click()
    refute_enqueued(worker: SummaryJob)

    view |> element("#history-look-back") |> render_click()

    view
    |> form("#home-coach-message-form", coach_message: %{text: "I train at 7 now"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#home-coach-thread", "Mornings it is.")
    Repo.delete_all(Oban.Job)

    view |> element("#coach-back") |> render_click()
    assert_patch(view, ~p"/progress")
    assert_enqueued(worker: SummaryJob)
    assert has_element?(view, "#history-coach-summary [role=status]", "Updating your summary")
  end
end
