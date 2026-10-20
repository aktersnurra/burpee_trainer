defmodule BurpeeTrainer.Coach.Client.Deadline do
  @moduledoc "Surviving per-call meter; only transport is killed on deadline or caller death."
  use GenServer, restart: :temporary
  alias BurpeeTrainer.Coach.{Client, Ledger}
  alias BurpeeTrainer.Workouts.Error

  def run(opts, transport) do
    caller = self()
    ref = make_ref()
    args = {caller, ref, opts, transport}

    case DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__, args}) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, :process, ^pid, _} ->
            {:error, Error.new(:ledger_finalization_failed)}
        end

      {:error, _} ->
        {:error, Error.new(:provider_unavailable)}
    end
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({caller, ref, opts, transport}) do
    state = %{
      caller: caller,
      ref: ref,
      opts: opts,
      transport: transport,
      caller_monitor: Process.monitor(caller),
      task: nil,
      call: nil,
      started: System.monotonic_time(:millisecond),
      deadline: Keyword.fetch!(opts, :deadline_ms)
    }

    {:ok, state, {:continue, :reserve}}
  end

  @impl true
  def handle_continue(:reserve, state) do
    config =
      Keyword.get(state.opts, :config, Application.get_env(:burpee_trainer, :llm_provider, []))

    ledger = Keyword.fetch!(state.opts, :ledger)

    with true <- state.deadline > now(),
         true <- is_list(config) and Keyword.get(config, :enabled) === true,
         true <- BurpeeTrainer.Coach.enabled?(ledger.scope),
         :ok <- caller_present(state),
         {:ok, call} <-
           Ledger.reserve(
             ledger.scope,
             %{
               purpose: ledger.purpose,
               run_id: ledger.run_id,
               model: Keyword.get(config, :model) || "unknown"
             },
             Keyword.put(
               Keyword.get(state.opts, :budget, []),
               :timeout,
               max(1, state.deadline - now())
             )
           ) do
      start_transport(%{state | call: call}, config)
    else
      false ->
        finish(
          state,
          if(state.deadline <= now(), do: :provider_timeout, else: :provider_unavailable)
        )

      {:error, reason} ->
        finish(state, reason)
    end
  rescue
    _error in [DBConnection.ConnectionError, Exqlite.Error] -> finish(state, :ledger_unavailable)
  end

  defp start_transport(state, config) do
    if state.deadline <= now() or caller_present(state) != :ok do
      finish(state, :provider_timeout)
    else
      owner = self()
      transport = state.transport

      {:ok, pid} =
        Task.Supervisor.start_child(__MODULE__.Transport, fn ->
          send(owner, {:result, self(), transport.(config)})
        end)

      monitor = Process.monitor(pid)
      Process.send_after(self(), :deadline, max(state.deadline - now(), 0))
      {:noreply, %{state | task: {pid, monitor}}}
    end
  end

  @impl true
  def handle_info({:result, pid, result}, %{task: {pid, _}} = state) do
    if now() >= state.deadline,
      do: finish(state, :provider_timeout),
      else: complete(state, result)
  end

  def handle_info(:deadline, state), do: finish(state, :provider_timeout)

  def handle_info({:DOWN, ref, :process, _, _}, %{caller_monitor: ref} = state),
    do: finish(state, :provider_cancelled)

  def handle_info({:DOWN, ref, :process, _, _}, %{task: {_, ref}} = state),
    do: finish(state, :provider_unavailable)

  defp finish(state, code), do: complete(state, {:error, Error.new(code)})

  defp complete(state, result) do
    cancel_transport(state.task)

    result =
      if state.call do
        Client.record_result(
          Keyword.fetch!(state.opts, :ledger),
          state.call,
          state.started,
          result,
          timeout: 1_000
        )
      else
        result
      end

    send(state.caller, {state.ref, result})
    {:stop, :normal, state}
  end

  defp cancel_transport(nil), do: :ok

  defp cancel_transport({pid, ref}) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
  end

  defp caller_present(state) do
    receive do
      {:DOWN, ref, :process, _, _} when ref == state.caller_monitor ->
        {:error, :provider_cancelled}
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
