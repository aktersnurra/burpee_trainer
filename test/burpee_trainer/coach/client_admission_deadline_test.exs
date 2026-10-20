defmodule BurpeeTrainer.Coach.ClientAdmissionDeadlineTest do
  use ExUnit.Case, async: false
  import BurpeeTrainer.Fixtures
  import ExUnit.CaptureLog
  alias BurpeeTrainer.{Accounts.User, Repo}
  alias BurpeeTrainer.Coach.{Client, LlmCall}
  alias Exqlite.Sqlite3

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, sandbox: false)
    scope = scope_fixture()
    Ecto.Adapters.SQL.query!(Repo, "PRAGMA busy_timeout=#{Map.get(tags, :busy_timeout, 5)}", [])
    {:ok, writer} = Sqlite3.open(Repo.config()[:database])
    :ok = Sqlite3.execute(writer, "BEGIN IMMEDIATE")

    on_exit(fn ->
      Sqlite3.execute(writer, "ROLLBACK")
      Sqlite3.close(writer)

      drain_admission()

      stop_owner(owner)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Ecto.Adapters.SQL.query!(Repo, "PRAGMA busy_timeout=2000", [])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DROP TRIGGER IF EXISTS analytics_admission_finish_failure",
          []
        )

        Repo.delete!(Repo.get!(User, scope.user.id))
      end)
    end)

    %{scope: scope, writer: writer, sandbox_owner: owner}
  end

  for busy_timeout <- [5, 2000] do
    @tag busy_timeout: busy_timeout
    test "real writer lock with #{busy_timeout}ms busy wait cannot extend admission or create a late reservation",
         ctx do
      owner = self()
      started = System.monotonic_time(:millisecond)

      caller =
        start_supervised!(
          {Task, fn -> send(owner, {:result, call(ctx.scope, started + 120, owner)}) end}
        )

      ref = Process.monitor(caller)
      # Keep the real writer held until after the result, not merely until expiry.
      assert_receive {:result, {:error, %{code: :provider_timeout}}}, 620
      assert System.monotonic_time(:millisecond) - started < 620
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
      :ok = Sqlite3.execute(ctx.writer, "ROLLBACK")
      drain_admission()
      stop_owner(ctx.sandbox_owner)

      assert Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Repo.aggregate(LlmCall, :count) end) ==
               0

      refute_received :transport_started
    end
  end

  for busy_timeout <- [5, 2000] do
    @tag busy_timeout: busy_timeout
    test "caller death during #{busy_timeout}ms lock contention cancels admission before lock release",
         ctx do
      owner = self()

      caller =
        start_supervised!(
          {Task, fn -> call(ctx.scope, System.monotonic_time(:millisecond) + 1000, owner) end}
        )

      admission = await_reservation_task()

      [{_, meter, _, _}] =
        DynamicSupervisor.which_children(BurpeeTrainer.Coach.Client.Deadline.Supervisor)

      ref = Process.monitor(meter)
      admission_ref = Process.monitor(admission)
      Process.exit(caller, :kill)
      # Synchronize cancellation at the responsive meter before releasing the writer.
      assert %{cancelled: :provider_cancelled} = await_cancellation(meter)
      :ok = Sqlite3.execute(ctx.writer, "ROLLBACK")
      assert_receive {:DOWN, ^admission_ref, :process, ^admission, :normal}, 2500
      assert_receive {:DOWN, ^ref, :process, ^meter, :normal}, 2500
      stop_owner(ctx.sandbox_owner)

      assert Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Repo.aggregate(LlmCall, :count) end) ==
               0

      refute_received :transport_started
    end
  end

  for finish_failure <- [false, true] do
    @tag busy_timeout: 2000
    @tag finish_failure: finish_failure
    test "a committed cancellation race conserves accounting with finish failure #{finish_failure}",
         ctx do
      owner = self()

      caller =
        start_supervised!(
          {Task, fn -> call(ctx.scope, System.monotonic_time(:millisecond) + 5000, owner) end}
        )

      admission = await_reservation_task()

      [{_, meter, _, _}] =
        DynamicSupervisor.which_children(BurpeeTrainer.Coach.Client.Deadline.Supervisor)

      :erlang.suspend_process(meter)
      # Force the successful admission to queue before the meter observes caller death.
      admission_ref = Process.monitor(admission)
      :ok = Sqlite3.execute(ctx.writer, "ROLLBACK")
      assert_receive {:DOWN, ^admission_ref, :process, ^admission, :normal}, 2500
      caller_ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

      if ctx.finish_failure do
        Ecto.Adapters.SQL.query!(
          Repo,
          "CREATE TRIGGER analytics_admission_finish_failure BEFORE UPDATE ON llm_calls BEGIN SELECT RAISE(ABORT, 'finish failed'); END",
          []
        )
      end

      log =
        capture_log(fn ->
          :erlang.resume_process(meter)
          drain_admission()
        end)

      expected = if ctx.finish_failure, do: "inflight", else: "cancelled"
      assert [%{outcome: ^expected, cost_usd: nil, prompt_tokens: nil}] = Repo.all(LlmCall)

      if ctx.finish_failure,
        do: assert(log =~ "analytics_admission_cleanup_failed code=ledger_finalization_failed")

      refute_received :transport_started
    end
  end

  defp drain_admission do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(BurpeeTrainer.Coach.Client.Deadline.Supervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3000
    end

    assert Task.Supervisor.children(BurpeeTrainer.Coach.Client.Deadline.Admission) == []
  end

  defp stop_owner(owner) do
    ref = Process.monitor(owner)

    receive do
      {:DOWN, ^ref, :process, ^owner, _} -> :ok
    after
      0 ->
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
        assert_receive {:DOWN, ^ref, :process, ^owner, _}
    end
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp call(scope, deadline, owner) do
    Client.chat([],
      config: [enabled: true, url: "http://recorded.test", api_key: "local", model: "recorded"],
      req:
        Req.new(
          adapter: fn request ->
            send(owner, :transport_started)
            {request, Req.Response.new(status: 500)}
          end
        ),
      deadline_ms: deadline,
      ledger: %{scope: scope, purpose: "analytics", run_id: Ecto.UUID.generate()}
    )
  end

  defp await_reservation_task(attempts \\ 100) do
    case Task.Supervisor.children(BurpeeTrainer.Coach.Client.Deadline.Admission) do
      [pid] when attempts > 0 ->
        {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

        await_reservation_stack(stack, pid, attempts)

      [] when attempts > 0 ->
        retry(fn -> await_reservation_task(attempts - 1) end)

      _ ->
        flunk("reservation task did not start")
    end
  end

  defp await_reservation_stack(stack, pid, attempts) do
    if Enum.any?(stack, fn {module, _, _, _} -> module == Repo end),
      do: pid,
      else: retry(fn -> await_reservation_task(attempts - 1) end)
  end

  defp await_cancellation(pid, attempts \\ 100) do
    case :sys.get_state(pid) do
      %{cancelled: :provider_cancelled} = state -> state
      _ when attempts > 0 -> retry(fn -> await_cancellation(pid, attempts - 1) end)
      _ -> flunk("reservation meter did not accept caller cancellation")
    end
  end

  defp retry(fun) do
    receive do
    after
      1 -> fun.()
    end
  end
end
