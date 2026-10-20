defmodule BurpeeTrainer.Analytics do
  @moduledoc "Authenticated read-only training analysis; trusted options are never MCP input."
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Analytics.{Analyst, Limits}
  alias BurpeeTrainer.Workouts.Error

  def analyze(scope, prompt, opts \\ [])

  def analyze(%Scope{} = scope, prompt, opts) when is_list(opts) do
    cond do
      not Limits.text?(prompt, Limits.prompt_bytes()) -> {:error, Error.new(:invalid_prompt)}
      not BurpeeTrainer.Coach.enabled?(scope) -> {:error, Error.new(:provider_unavailable)}
      true -> supervised(scope, prompt, opts)
    end
  end

  def analyze(_, _, _), do: {:error, Error.new(:invalid_input)}

  defp supervised(scope, prompt, opts) do
    caller = self()
    # A trusted test/operator may tighten, but never extend the production deadline.
    duration = max(1, min(Limits.run_ms(), Keyword.get(opts, :run_timeout_ms, Limits.run_ms())))
    deadline = System.monotonic_time(:millisecond) + duration
    ref = make_ref()
    trace_id = Ecto.UUID.generate()

    {:ok, guardian} =
      Task.Supervisor.start_child(BurpeeTrainer.Analytics.RunSupervisor, fn ->
        caller_ref = Process.monitor(caller)

        worker =
          Task.Supervisor.async_nolink(BurpeeTrainer.Analytics.RunSupervisor, fn ->
            Analyst.run(scope, prompt, opts, deadline, trace_id)
          end)

        await(caller, caller_ref, ref, worker, deadline, scope, trace_id)
      end)

    monitor = Process.monitor(guardian)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^guardian, _} ->
        {:error, Error.new(:analytics_unavailable)}
    end
  end

  defp await(caller, caller_ref, ref, worker, deadline, scope, trace_id) do
    task_ref = worker.ref

    receive do
      {^task_ref, result} ->
        Process.demonitor(worker.ref, [:flush])
        send(caller, {ref, result})

      {:DOWN, ^caller_ref, :process, ^caller, _} ->
        Process.exit(worker.pid, :kill)

      {:DOWN, ^task_ref, :process, _, _} ->
        send(caller, {ref, {:error, Error.new(:analytics_unavailable)}})
    after
      max(0, deadline - Limits.reserve_ms() - System.monotonic_time(:millisecond)) ->
        Process.exit(worker.pid, :kill)
        send(caller, {ref, BurpeeTrainer.Analytics.Trace.timeout(scope, trace_id, deadline)})
    end
  end
end
