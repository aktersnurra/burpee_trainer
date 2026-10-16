defmodule BurpeeTrainer.Coach.PlannerEnqueueConcurrencyTest do
  use ExUnit.Case, async: false
  import BurpeeTrainer.Fixtures
  import Ecto.Query
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Coach.PlanNextWorkoutJob
  alias Ecto.Adapters.SQL.Sandbox

  test "independent SQLite connections serialize Lite unique SELECT and INSERT" do
    assert Repo.config()[:pool] == Sandbox
    path = Repo.config()[:database]
    assert is_binary(path)
    scope = Sandbox.unboxed_run(Repo, fn -> scope_fixture() end)

    IO.puts(
      "planner concurrency owner id=#{scope.user.id} username=#{scope.user.username} database=#{path}"
    )

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.get_by(BurpeeTrainer.Accounts.User,
                 id: scope.user.id,
                 username: scope.user.username
               )

        Repo.delete_all(
          from j in Oban.Job,
            where:
              j.worker == "BurpeeTrainer.Coach.PlanNextWorkoutJob" and
                fragment("json_extract(?, '$.user_id')", j.args) == ^scope.user.id
        )

        assert {1, _} =
                 Repo.delete_all(
                   from u in BurpeeTrainer.Accounts.User,
                     where: u.id == ^scope.user.id and u.username == ^scope.user.username
                 )

        IO.puts("planner concurrency cleanup exact owner id=#{scope.user.id}; jobs/user deleted")
      end)
    end)

    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:burpee_trainer, :repo, :query],
        fn _, _, meta, _ ->
          if String.starts_with?(meta.query, "SELECT") and
               String.contains?(meta.query, "FROM \"oban_jobs\"") and
               String.contains?(meta.query, "LIMIT") do
            transactional = Repo.in_transaction?()
            send(parent, {:unique_read, self(), transactional})
            # On the unfixed path force the real two-connection SELECT/INSERT race.
            unless transactional do
              receive do
                :insert -> :ok
              end
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            assert [0, "main", path] in Repo.query!("PRAGMA database_list").rows
            # A same-named temporary table can exist concurrently only on distinct connections.
            Repo.query!("CREATE TEMP TABLE planner_connection_proof (identity TEXT)")
            Repo.query!("INSERT INTO planner_connection_proof VALUES (?)", [inspect(self())])
            send(parent, {:ready, self()})

            try do
              receive do
                :enqueue ->
                  result = PlanNextWorkoutJob.enqueue(scope)

                  assert [[identity]] =
                           Repo.query!("SELECT identity FROM planner_connection_proof").rows

                  assert identity == inspect(self())
                  result
              end
            after
              Repo.query!("DROP TABLE planner_connection_proof")
            end
          end)
        end)
      end

    assert_receive {:ready, first}, 1000
    assert_receive {:ready, second}, 1000
    send(first, :enqueue)
    send(second, :enqueue)
    assert_receive {:unique_read, reader1, transaction1}, 3000

    if transaction1 do
      assert_receive {:unique_read, reader2, true}, 3000
      refute reader1 == reader2
    else
      assert_receive {:unique_read, reader2, false}, 3000
      refute reader1 == reader2
      send(reader1, :insert)
      send(reader2, :insert)
    end

    assert Enum.map(tasks, &Task.await(&1)) == [:ok, :ok]

    count =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.aggregate(
          from(j in Oban.Job,
            where:
              j.worker == "BurpeeTrainer.Coach.PlanNextWorkoutJob" and
                fragment("json_extract(?, '$.user_id')", j.args) == ^scope.user.id
          ),
          :count
        )
      end)

    assert count == 1
    assert transaction1
  end
end
