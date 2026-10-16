defmodule BurpeeTrainer.TestDatabaseConfigTest do
  use BurpeeTrainer.DataCase, async: false

  test "owned database configuration survives an independent VM" do
    path = BurpeeTrainer.Repo.config()[:database]
    assert BurpeeTrainer.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox

    if configured = System.get_env("BURPEE_TRAINER_TEST_DATABASE_PATH") do
      assert path == configured
    end

    assert [0, "main", path] in BurpeeTrainer.Repo.query!("PRAGMA database_list").rows

    expression = """
    config = Config.Reader.read!("config/test.exs", env: :test, target: :host)
    repo = config |> Keyword.fetch!(:burpee_trainer) |> Keyword.fetch!(BurpeeTrainer.Repo)
    true = repo[:database] == System.fetch_env!("BURPEE_TRAINER_TEST_DATABASE_PATH")
    true = repo[:pool] == Ecto.Adapters.SQL.Sandbox
    IO.puts("owned-child-config")
    """

    assert {"owned-child-config\n", 0} =
             System.cmd("elixir", ["-e", expression],
               env: [{"BURPEE_TRAINER_TEST_DATABASE_PATH", path}],
               stderr_to_stdout: true
             )
  end

  test "relative overrides fail before any Repo starts" do
    expression = "Config.Reader.read!(\"config/test.exs\", env: :test, target: :host)"

    {output, status} =
      System.cmd("elixir", ["-e", expression],
        env: [{"BURPEE_TRAINER_TEST_DATABASE_PATH", "relative.sqlite3"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "BURPEE_TRAINER_TEST_DATABASE_PATH must be an absolute path"
  end
end
