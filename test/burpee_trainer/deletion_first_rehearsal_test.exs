defmodule BurpeeTrainer.DeletionFirstRehearsalTest do
  use ExUnit.Case, async: false

  @script "scripts/migrations/rehearse_deletion_first.exs"
  @source "/tmp/deletion-first-source-backup.db"
  @target "/tmp/deletion-first-migration-rehearsal.db"
  @paths for path <- [@source, @target], suffix <- ["", "-shm", "-wal"], do: path <> suffix
  @sentinels [
    "/tmp/deletion-first-neighbor-sentinel.txt",
    "/tmp/deletion-first-migration-rehearsal.db-neighbor"
  ]

  setup do
    clear_paths!()
    clear_sentinels!()

    on_exit(fn ->
      clear_paths!()
      clear_sentinels!()
    end)

    :ok
  end

  test "rehearsal refuses every command-line argument without touching marked paths" do
    marker = "do-not-remove"
    sentinel_markers = write_sentinels!()
    File.write!(@source, marker)

    {output, status} = run_rehearsal(["/tmp/deletion-first-other.db"])

    assert status != 0
    assert output =~ "rehearsal accepts no path arguments"
    assert File.read!(@source) == marker
    refute File.exists?(@target)
    assert_sentinels_unchanged!(sentinel_markers)
  end

  test "rehearsal uses the isolated test repo and contains no application-repo or copy escape hatch" do
    source = File.read!(@script)

    assert source =~ "BurpeeTrainer.TestSupport.IsolatedMigrationRepo"
    assert source =~ "VACUUM INTO"
    assert source =~ "start_isolated_repo!(@source, 1)"
    assert source =~ "start_isolated_repo!(@source, 5)"
    refute source =~ "BurpeeTrainer.Repo.start_link"
    refute source =~ "Application.put_env(:burpee_trainer, BurpeeTrainer.Repo"
    refute source =~ "DATABASE_PATH"
    refute source =~ "MIX_ENV=dev"
    refute source =~ "File.cp"
  end

  test "rehearsal proves atomic forward facts, exact restore, and neighboring-file safety" do
    sentinel_markers = write_sentinels!()
    {output, status} = run_rehearsal([])

    assert status == 0, output
    report = output |> report_line!("DELETION_FIRST_REHEARSAL=") |> Jason.decode!()

    assert report == %{
             "application_repo_started" => false,
             "forward" => %{
               "foreign_key_check" => [],
               "foreign_keys" => 1,
               "helpers" => [],
               "preserved" => true
             },
             "paths" => [@source, @target],
             "restore" => %{"exact" => true},
             "source_construction" => %{
               "historical_pool_size" => 1,
               "reopened_pool_size" => 5,
               "stopped_before_seed" => true
             },
             "source_version" => 20_260_827_200_641,
             "status" => "ok"
           }

    refute Enum.any?(@paths, &File.exists?/1)
    assert_sentinels_unchanged!(sentinel_markers)
  end

  defp run_rehearsal(arguments) do
    System.cmd(
      "mix",
      ["run", "--no-start", @script, "--" | arguments],
      cd: File.cwd!(),
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp report_line!(output, prefix) do
    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
    |> case do
      nil -> flunk("missing #{prefix} in output:\n#{output}")
      report -> report
    end
  end

  defp write_sentinels! do
    Map.new(@sentinels, fn path ->
      marker = "sentinel:#{Path.basename(path)}"
      File.write!(path, marker)
      {path, marker}
    end)
  end

  defp assert_sentinels_unchanged!(markers) do
    Enum.each(markers, fn {path, marker} -> assert File.read!(path) == marker end)
  end

  defp clear_sentinels! do
    Enum.each(@sentinels, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise "cannot clear test sentinel #{path}: #{inspect(reason)}"
      end
    end)
  end

  defp clear_paths! do
    Enum.each(@paths, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise "cannot clear test path #{path}: #{inspect(reason)}"
      end
    end)
  end
end
