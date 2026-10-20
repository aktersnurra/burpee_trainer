defmodule BurpeeTrainer.Coach.Client.Deadline do
  @moduledoc "Surviving per-call meter; admission drains, only transport is killed on cancellation."
  use GenServer, restart: :temporary
  require Logger
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
    deadline = Keyword.fetch!(opts, :deadline_ms)
    Process.send_after(self(), :deadline, max(deadline - now(), 0))

    state = %{
      caller: caller,
      ref: ref,
      opts: opts,
      transport: transport,
      caller_monitor: Process.monitor(caller),
      task: nil,
      admission: nil,
      cancellation: :atomics.new(1, []),
      cancelled: nil,
      replied: false,
      config: nil,
      call: nil,
      started: now(),
      deadline: deadline
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
         :ok <- caller_present(state) do
      start_admission(%{state | config: config}, ledger)
    else
      false ->
        finish(
          state,
          if(state.deadline <= now(), do: :provider_timeout, else: :provider_unavailable)
        )

      {:error, reason} ->
        finish(state, reason)
    end
  end

  defp start_admission(state, ledger) do
    owner = self()

    case Task.Supervisor.start_child(__MODULE__.Admission, fn ->
           send(owner, {:admission, self(), reserve(state, ledger)})
         end) do
      {:ok, pid} ->
        {:noreply, %{state | admission: {pid, Process.monitor(pid)}}}

      {:error, _} ->
        finish(state, :provider_unavailable)
    end
  end

  defp reserve(state, ledger) do
    caller_monitor = Process.monitor(state.caller)

    Ledger.reserve(
      ledger.scope,
      %{
        purpose: ledger.purpose,
        run_id: ledger.run_id,
        model: Keyword.get(state.config, :model) || "unknown"
      },
      Keyword.merge(Keyword.get(state.opts, :budget, []),
        timeout: max(1, state.deadline - now()),
        deadline_ms: state.deadline,
        admission_check: fn -> admission_check(state, caller_monitor) end
      )
    )
  rescue
    _error in [DBConnection.ConnectionError, Exqlite.Error] -> {:error, :ledger_unavailable}
  end

  defp admission_check(state, caller_monitor) do
    case :atomics.get(state.cancellation, 1) do
      0 ->
        if now() >= state.deadline,
          do: {:error, :provider_timeout},
          else: caller_present(%{state | caller_monitor: caller_monitor})

      1 ->
        {:error, :provider_timeout}

      2 ->
        {:error, :provider_cancelled}
    end
  end

  defp start_transport(state) do
    cond do
      state.deadline <= now() -> finish(state, :provider_timeout)
      caller_present(state) != :ok -> finish(state, :provider_cancelled)
      true -> launch_transport(state)
    end
  end

  defp launch_transport(state) do
    owner = self()
    transport = state.transport
    config = state.config

    {:ok, pid} =
      Task.Supervisor.start_child(__MODULE__.Transport, fn ->
        send(owner, {:result, self(), transport.(config)})
      end)

    {:noreply, %{state | task: {pid, Process.monitor(pid)}}}
  end

  @impl true
  def handle_info({:admission, pid, result}, %{admission: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    reconcile_admission(%{state | admission: nil}, result)
  end

  def handle_info({:result, pid, result}, %{task: {pid, _}} = state) do
    if now() >= state.deadline,
      do: finish(state, :provider_timeout),
      else: complete(state, result)
  end

  def handle_info(:deadline, state), do: cancel(state, :provider_timeout)

  def handle_info({:DOWN, ref, :process, _, _}, %{caller_monitor: ref} = state),
    do: cancel(state, :provider_cancelled)

  def handle_info({:DOWN, ref, :process, _, _}, %{admission: {_, ref}} = state),
    do: finish(%{state | admission: nil}, :ledger_unavailable)

  def handle_info({:DOWN, ref, :process, _, _}, %{task: {_, ref}} = state),
    do: finish(state, :provider_unavailable)

  defp reconcile_admission(state, {:ok, call}) do
    state = %{state | call: call}
    if state.cancelled, do: finish(state, state.cancelled), else: start_transport(state)
  end

  defp reconcile_admission(state, {:error, reason}) do
    reason =
      cond do
        state.cancelled -> state.cancelled
        now() >= state.deadline or reason == :deadline_exceeded -> :provider_timeout
        true -> reason
      end

    finish(state, reason)
  end

  # Never kill admission: a dirty BEGIN may still be waiting for SQLite. Signal
  # rollback, reply promptly, then drain and meter any commit/cancellation race.
  defp cancel(%{admission: {_, _}, cancelled: nil} = state, reason) do
    :atomics.put(state.cancellation, 1, if(reason == :provider_timeout, do: 1, else: 2))
    state = reply(state, {:error, Error.new(reason)})
    {:noreply, %{state | cancelled: reason}}
  end

  defp cancel(%{cancelled: reason} = state, _) when not is_nil(reason), do: {:noreply, state}
  defp cancel(state, reason), do: finish(state, reason)

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

    if match?({:error, %{code: :ledger_finalization_failed}}, result) do
      Logger.warning("analytics_admission_cleanup_failed code=ledger_finalization_failed")
    end

    state = reply(state, result)
    {:stop, :normal, state}
  end

  defp reply(%{replied: true} = state, _result), do: state

  defp reply(state, result) do
    send(state.caller, {state.ref, result})
    %{state | replied: true}
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
