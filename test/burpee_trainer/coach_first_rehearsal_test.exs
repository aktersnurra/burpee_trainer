defmodule BurpeeTrainer.CoachFirstRehearsalTest do
  use ExUnit.Case, async: false

  @script "scripts/migrations/rehearse_coach_first.exs"

  setup do
    owned = Path.join(System.tmp_dir!(), "coach-first-rehearsal-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(owned)

    on_exit(fn -> File.rm_rf!(owned) end)
    %{owned: owned}
  end

  test "rehearsal refuses arguments without touching caller-owned paths", %{owned: owned} do
    caller_path = Path.join(owned, "caller.db")
    sentinel = Path.join(owned, "neighbor-sentinel.txt")
    File.write!(caller_path, "caller-owned database marker")
    File.write!(sentinel, "neighbor sentinel")

    {output, status} = run_rehearsal([caller_path])

    assert status != 0
    assert output =~ "rehearsal accepts no path arguments"
    assert File.read!(caller_path) == "caller-owned database marker"
    assert File.read!(sentinel) == "neighbor sentinel"
  end

  test "rehearsal uses only its owned isolated database paths and restores exact source facts", %{
    owned: owned
  } do
    sentinel = Path.join(owned, "neighbor-sentinel.txt")
    File.write!(sentinel, "must survive rehearsal")

    {output, status} = run_rehearsal([])

    assert status == 0, output
    report = output |> report_line!() |> Jason.decode!()

    assert report["status"] == "ok"
    assert report["application_repo_started"] == false

    assert report["forward"] == %{
             "foreign_key_check" => [],
             "foreign_keys" => 1,
             "preserved" => true
           }

    assert report["restore"]["exact"] == true
    assert report["restore"]["source_unchanged"] == true
    assert report["restore"]["migration_metadata_preserved"] == true
    assert is_binary(report["restore"]["snapshot_sha256"])
    assert String.length(report["restore"]["snapshot_sha256"]) == 64

    rehearsal_dir = report["owned_directory"]
    assert String.starts_with?(rehearsal_dir, System.tmp_dir!())
    refute String.starts_with?(rehearsal_dir, owned)
    refute File.exists?(rehearsal_dir)
    assert File.read!(sentinel) == "must survive rehearsal"
  end

  defp run_rehearsal(arguments) do
    System.cmd(
      "mix",
      ["run", "--no-start", @script, "--" | arguments],
      cd: File.cwd!(),
      env: [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 4:4"}],
      stderr_to_stdout: true
    )
  end

  defp report_line!(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      String.replace_prefix(line, "COACH_FIRST_REHEARSAL=", "")
      |> case do
        ^line -> nil
        report -> report
      end
    end)
    |> case do
      nil -> flunk("missing rehearsal report in output:\n#{output}")
      report -> report
    end
  end
end
