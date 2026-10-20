defmodule BurpeeTrainer.Analytics.ExecutorTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.Analytics.{Executor, HelperGuardian, Snapshot}

  test "actual launcher aggregates an immutable snapshot and refuses unsafe SQL" do
    snapshot = %Snapshot{
      rows: [
        [
          1,
          "2026-10-20T00:00:00Z",
          "2026-10-20",
          "manual",
          "six_count",
          "logged",
          30,
          100,
          600,
          1200,
          600,
          0,
          20.0,
          60
        ]
      ],
      as_of: ~U[2026-10-20 00:00:00Z],
      timezone: "Etc/UTC"
    }

    assert {:ok, %{columns: ["reps"], rows: [[30]], duration_ms: ms}} =
             Executor.query(snapshot, "SELECT sum(reps_actual) AS reps FROM sessions")

    assert ms <= 1000
    assert {:error, :sql_denied} = Executor.query(snapshot, "DELETE FROM sessions")
    assert {:error, :sql_denied} = Executor.query(snapshot, "SELECT randomblob(10000000)")
    assert {:ok, %{rows: [[30]]}} = Executor.query(snapshot, "SELECT reps_actual FROM sessions")
  end

  test "two-helper admission has no waiting queue and a tightened deadline kills the worker" do
    parent = self()

    for id <- [:one, :two] do
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(
               parent,
               {id, Executor.query(pressure_snapshot(), pressure_sql(), timeout_ms: 600)}
             )
           end},
          id: id
        )
      )
    end

    await_active(2, System.monotonic_time(:millisecond) + 500)
    assert {:error, :executor_busy} = Executor.query(%Snapshot{}, "SELECT 1")
    assert_receive {:one, {:error, :query_timeout}}, 1500
    assert_receive {:two, {:error, :query_timeout}}, 1500
    assert {:ok, %{rows: [[1]]}} = Executor.query(%Snapshot{}, "SELECT 1 AS n")
  end

  test "caller and guardian death terminate the actual sandbox worker" do
    for target <- [:caller, :guardian] do
      caller =
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               Executor.query(pressure_snapshot(), pressure_sql())
             end},
            id: target,
            restart: :temporary
          )
        )

      state = await_active(1, System.monotonic_time(:millisecond) + 500)
      [port] = Map.keys(state.active)
      {:os_pid, launcher} = Port.info(port, :os_pid)
      worker = find_worker(launcher, System.monotonic_time(:millisecond) + 500)
      monitor_port = monitor_worker(worker)
      assert_receive {^monitor_port, {:data, "ready\n"}}, 500
      pid = if target == :caller, do: caller, else: Process.whereis(HelperGuardian)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert_receive {^monitor_port, {:data, "gone\n"}}, 1500
      assert_receive {^monitor_port, {:exit_status, 0}}, 500
      await_active(0, System.monotonic_time(:millisecond) + 1500)
    end
  end

  defp pressure_snapshot do
    %Snapshot{
      rows:
        List.duplicate(
          [
            1,
            "2026-10-20T00:00:00Z",
            "2026-10-20",
            "manual",
            "six_count",
            "logged",
            30,
            100,
            600,
            1200,
            600,
            0,
            20.0,
            60
          ],
          1000
        )
    }
  end

  defp pressure_sql,
    do:
      "SELECT sum(a.reps_actual*b.reps_actual*c.reps_actual) AS n FROM sessions a, sessions b, sessions c"

  defp await_active(count, deadline) do
    state = :sys.get_state(HelperGuardian)

    cond do
      map_size(state.active) == count ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("helper admission did not reach #{count}")

      true ->
        await_active(count, deadline)
    end
  end

  defp find_worker(launcher, deadline) do
    case descendants(launcher) |> Enum.find(&worker?/1) do
      nil ->
        assert System.monotonic_time(:millisecond) < deadline, "no sandbox worker observed"
        find_worker(launcher, deadline)

      worker ->
        worker
    end
  end

  defp descendants(pid) do
    case File.read("/proc/#{pid}/task/#{pid}/children") do
      {:ok, children} ->
        pids = children |> String.split() |> Enum.map(&String.to_integer/1)
        pids ++ Enum.flat_map(pids, &descendants/1)

      _ ->
        []
    end
  end

  defp worker?(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, bytes} ->
        args = String.split(bytes, <<0>>)
        "/helper.py" in args and "--ro-bind" not in args

      _ ->
        false
    end
  end

  defp monitor_worker(pid) do
    code =
      "import os,select; f=os.pidfd_open(#{pid}); p=select.poll(); p.register(f,select.POLLIN); print('ready',flush=True); assert p.poll(2000); print('gone',flush=True)"

    Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
      :binary,
      :exit_status,
      {:args, [~c"-I", ~c"-c", String.to_charlist(code)]}
    ])
  end

  test "caller cannot relax limits or send malformed snapshots" do
    assert {:error, :invalid_input} = Executor.query(%Snapshot{}, "SELECT 1", timeout_ms: 1001)
    assert {:error, :invalid_input} = Executor.query(%Snapshot{}, "SELECT 1", timeout_ms: 0)
    assert {:error, :invalid_input} = Executor.query(%Snapshot{}, String.duplicate("x", 4097))
    assert {:error, :invalid_input} = Executor.query(%Snapshot{rows: [["SECRET"]]}, "SELECT 1")
    assert {:error, :invalid_input} = Executor.query(%Snapshot{}, "SELECT 1", [123])
    assert {:error, :invalid_input} = Executor.query(%Snapshot{}, "SELECT 1", timeout_ms: "1")
    assert {:error, :invalid_input} = Executor.query(%Snapshot{}, "SELECT 1", unknown: true)
  end
end
