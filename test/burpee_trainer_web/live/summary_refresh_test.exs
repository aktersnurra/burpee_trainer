defmodule BurpeeTrainerWeb.SummaryRefreshTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Summary, SummaryJob}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    free_form_session_fixture(user)
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), scope: Scope.for_user(user)}
  end

  test "opening with this week's summary shows it without a refresh", %{
    conn: conn,
    scope: scope
  } do
    {:ok, _} = Summary.store(scope, %{text: "Current.", metric_ids: [], source: :llm})
    {:ok, view, _html} = live(conn, ~p"/progress")

    assert %{progress_summary_loading?: false, progress_summary: %Summary{text: "Current."}} =
             assigns(view)

    assert all_enqueued(worker: SummaryJob) == []
  end

  defp assigns(view) do
    _ = render(view)
    :sys.get_state(view.pid).socket.assigns
  end
end
