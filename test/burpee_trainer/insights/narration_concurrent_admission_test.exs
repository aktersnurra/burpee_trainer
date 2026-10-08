defmodule BurpeeTrainer.Insights.NarrationConcurrentAdmissionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, Repo}
  alias BurpeeTrainer.Insights.NarrateJob
  alias Ecto.Adapters.SQL.Sandbox

  test "independent SQLite connections serialize unique Lite narration admission" do
    assert Repo.config()[:pool] == Sandbox

    databases = Ecto.Adapters.SQL.query!(Repo, "PRAGMA database_list", []).rows
    assert [0, "main", database] = Enum.find(databases, &(Enum.at(&1, 1) == "main"))
    assert database == Path.expand(Repo.config()[:database])
    assert Enum.all?(databases, &(&1 == [0, "main", database] or &1 == [1, "temp", ""]))

    {scope, session} =
      Sandbox.unboxed_run(Repo, fn ->
        scope = scope_fixture()
        File.mkdir_p!(".e2e-artifacts/combined/concurrency")

        File.write!(
          ".e2e-artifacts/combined/concurrency/narration-owner-#{Ecto.UUID.generate()}.json",
          Jason.encode!(%{id: scope.user.id, username: scope.user.username})
        )

        {scope, free_form_session_fixture(scope.user)}
      end)

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    try do
      tasks =
        for marker <- [1, 2] do
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              # Same TEMP table name on both held checkouts proves separate connections.
              Ecto.Adapters.SQL.query!(
                Repo,
                "CREATE TEMP TABLE narration_connection_probe (marker INTEGER)",
                []
              )

              try do
                Ecto.Adapters.SQL.query!(
                  Repo,
                  "INSERT INTO narration_connection_probe VALUES (?)",
                  [marker]
                )

                send(parent, {:connection_ready, self(), marker})

                receive do
                  :admit -> :ok
                end

                result = NarrateJob.enqueue(scope, session)

                assert [[^marker]] =
                         Ecto.Adapters.SQL.query!(
                           Repo,
                           "SELECT marker FROM narration_connection_probe",
                           []
                         ).rows

                result
              after
                Ecto.Adapters.SQL.query!(Repo, "DROP TABLE narration_connection_probe", [])
              end
            end)
          end)
        end

      assert_receive {:connection_ready, one, 1}
      assert_receive {:connection_ready, two, 2}
      assert one != two
      send(one, :admit)
      send(two, :admit)
      assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &Task.await/1)
      assert first.id == second.id

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(Oban.Job, :count) == 1
      end)
    after
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from j in Oban.Job,
            where:
              j.worker == "BurpeeTrainer.Insights.NarrateJob" and
                fragment("json_extract(?, '$.user_id')", j.args) == ^scope.user.id
        )

        assert %{username: username} = Accounts.get_user(scope.user.id)
        assert username == scope.user.username
        Repo.delete!(Accounts.get_user(scope.user.id))
      end)
    end
  end
end
