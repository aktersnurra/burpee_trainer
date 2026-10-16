defmodule BurpeeTrainerWeb.SummaryRefreshTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite

  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Summary, SummaryJob}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    free_form_session_fixture(user)
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), scope: Scope.for_user(user)}
  end

  test "opening with last week's summary shows loading until the new one arrives", %{
    conn: conn,
    scope: scope
  } do
    {:ok, old} = Summary.store(scope, %{text: "Old.", metric_ids: [], source: :llm})

    Repo.update_all(from(s in Summary, where: s.id == ^old.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -8, :day)]
    )

    {:ok, view, _html} = live(conn, ~p"/progress")

    assert %{progress_summary_loading?: true, progress_summary: %Summary{text: "Old."}} =
             assigns(view)

    assert length(all_enqueued(worker: SummaryJob)) == 1

    {:ok, new} = Summary.store(scope, %{text: "New.", metric_ids: [], source: :llm})
    Phoenix.PubSub.broadcast(BurpeeTrainer.PubSub, Summary.topic(scope), {:coach_summary, new})

    assert %{progress_summary_loading?: false, progress_summary: %Summary{text: "New."}} =
             assigns(view)
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
