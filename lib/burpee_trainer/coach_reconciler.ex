defmodule BurpeeTrainer.CoachReconciler do
  @moduledoc """
  Supervises best-effort reconciliation of each user's current coach slot.

  Queue and in-flight state live only in this process. A process restart recovers
  exclusively by scanning persisted user and recommendation state again.
  """

  use GenServer

  alias BurpeeTrainer.Accounts
  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts

  @default_task_supervisor BurpeeTrainer.CoachTaskSupervisor
  @default_scan_interval_ms :timer.minutes(5)
  @default_max_concurrency 2
  @wake_reasons [:completion, :timezone_changed, :date_transition, :retry]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec wake(pos_integer(), atom()) :: :ok
  def wake(user_id, reason)
      when is_integer(user_id) and user_id > 0 and reason in @wake_reasons do
    GenServer.cast(__MODULE__, {:wake, user_id, reason})
  end

  @spec scan_now() :: :ok
  def scan_now do
    GenServer.cast(__MODULE__, :scan_now)
  end

  @impl true
  def init(opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    if not (is_integer(max_concurrency) and max_concurrency > 0) do
      raise ArgumentError, ":max_concurrency must be a positive integer"
    end

    scan_interval_ms = Keyword.get(opts, :scan_interval_ms, @default_scan_interval_ms)

    if scan_interval_ms != :infinity and
         not (is_integer(scan_interval_ms) and scan_interval_ms > 0) do
      raise ArgumentError, ":scan_interval_ms must be a positive integer or :infinity"
    end

    state = %{
      date_timers: %{},
      in_flight: %{},
      max_concurrency: max_concurrency,
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      queue: :queue.new(),
      queued_user_ids: MapSet.new(),
      scan_interval_ms: scan_interval_ms,
      task_supervisor: Keyword.get(opts, :task_supervisor, @default_task_supervisor),
      user_page_query: Keyword.get(opts, :user_page_query, &Accounts.list_users_page/1)
    }

    {:ok, state, {:continue, :startup_scan}}
  end

  @impl true
  def handle_continue(:startup_scan, state) do
    state = scan(state)
    schedule_scan(state.scan_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:scan_now, state), do: {:noreply, scan(state)}

  def handle_cast({:wake, user_id, reason}, state) do
    {:noreply, state |> wake_user(user_id, reason, state.now.()) |> drain_queue()}
  end

  @impl true
  def handle_info(:periodic_scan, state) do
    state = scan(state)
    schedule_scan(state.scan_interval_ms)
    {:noreply, state}
  end

  def handle_info({:date_transition, user_id, token, transition_at}, state) do
    case Map.get(state.date_timers, user_id) do
      %{token: ^token, transition_at: ^transition_at} ->
        state = %{state | date_timers: Map.delete(state.date_timers, user_id)}

        {:noreply,
         state
         |> wake_user(user_id, :date_transition, transition_at)
         |> drain_queue()}

      _stale_or_missing ->
        {:noreply, state}
    end
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        {:noreply, state}

      {_task, in_flight} ->
        Process.demonitor(ref, [:flush])
        {:noreply, state |> Map.put(:in_flight, in_flight) |> drain_queue()}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        {:noreply, state}

      {_task, in_flight} ->
        {:noreply, state |> Map.put(:in_flight, in_flight) |> drain_queue()}
    end
  end

  defp scan(state) do
    state
    |> enqueue_user_pages(nil)
    |> drain_queue()
  end

  defp enqueue_user_pages(state, cursor) do
    users = state.user_page_query.(cursor)
    state = Enum.reduce(users, state, &enqueue_user(&2, &1))

    case List.last(users) do
      %User{id: user_id} -> enqueue_user_pages(state, user_id)
      nil -> state
    end
  end

  defp enqueue_user(state, %User{} = user) do
    now = state.now.()

    state
    |> schedule_date_transition(user, now)
    |> enqueue_reconciliation(user, now)
  end

  defp enqueue_reconciliation(state, %User{id: user_id} = user, %DateTime{} = now) do
    if MapSet.member?(state.queued_user_ids, user_id) do
      queue =
        state.queue
        |> :queue.to_list()
        |> Enum.map(fn
          {%User{id: ^user_id}, _queued_at} -> {user, now}
          queued_user -> queued_user
        end)
        |> :queue.from_list()

      %{state | queue: queue}
    else
      %{
        state
        | queue: :queue.in({user, now}, state.queue),
          queued_user_ids: MapSet.put(state.queued_user_ids, user_id)
      }
    end
  end

  defp drain_queue(state) when map_size(state.in_flight) >= state.max_concurrency, do: state

  defp drain_queue(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, {%User{} = user, %DateTime{} = now}}, queue} ->
        reconciler = self()

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            stop_when_reconciler_stops(reconciler)
            reconcile_user(user, now)
          end)

        state = %{
          state
          | queue: queue,
            queued_user_ids: MapSet.delete(state.queued_user_ids, user.id),
            in_flight: Map.put(state.in_flight, task.ref, %{pid: task.pid, user_id: user.id})
        }

        drain_queue(state)
    end
  end

  defp wake_user(state, user_id, _reason, %DateTime{} = now) do
    case Accounts.get_user(user_id) do
      %User{} = user ->
        state
        |> schedule_date_transition(user, now)
        |> enqueue_reconciliation(user, now)

      nil ->
        cancel_date_timer(state, user_id)
    end
  end

  defp schedule_date_transition(state, %User{} = user, %DateTime{} = now) do
    state = cancel_date_timer(state, user.id)

    case next_date_transition(user, now) do
      {:ok, transition_at} ->
        token = make_ref()
        delay_ms = max(DateTime.diff(transition_at, now, :millisecond), 0)

        timer_ref =
          Process.send_after(
            self(),
            {:date_transition, user.id, token, transition_at},
            delay_ms
          )

        timer = %{
          ref: timer_ref,
          timezone: user.timezone,
          token: token,
          transition_at: transition_at
        }

        %{state | date_timers: Map.put(state.date_timers, user.id, timer)}

      {:error, :invalid_timezone} ->
        state
    end
  end

  defp cancel_date_timer(state, user_id) do
    case Map.pop(state.date_timers, user_id) do
      {nil, _date_timers} ->
        state

      {%{ref: timer_ref}, date_timers} ->
        Process.cancel_timer(timer_ref)
        %{state | date_timers: date_timers}
    end
  end

  defp next_date_transition(%User{} = user, %DateTime{} = now) do
    with {:ok, context} <- BurpeeTrainer.UserTime.context(user, now),
         {:ok, local_midnight} <-
           BurpeeTrainer.UserTime.resolve_local(
             Date.add(context.date, 1),
             ~T[00:00:00],
             user.timezone
           ),
         {:ok, utc_midnight} <- DateTime.shift_zone(local_midnight, "Etc/UTC") do
      {:ok, utc_midnight}
    else
      _invalid -> {:error, :invalid_timezone}
    end
  end

  defp stop_when_reconciler_stops(reconciler) do
    task = self()

    spawn(fn ->
      reconciler_ref = Process.monitor(reconciler)
      task_ref = Process.monitor(task)

      receive do
        {:DOWN, ^reconciler_ref, :process, ^reconciler, _reason} -> Process.exit(task, :kill)
        {:DOWN, ^task_ref, :process, ^task, _reason} -> :ok
      end
    end)
  end

  defp reconcile_user(%User{} = user, %DateTime{} = now) do
    scope = Accounts.Scope.for_user(user)

    with {:ok, slot} <- Policy.required_slot(scope, DateTime.truncate(now, :second)),
         {:ok, recommendation} <-
           Workouts.ensure_recommendation(scope, %{
             slot_key: slot.slot_key,
             slot_date: slot.slot_date,
             rationale: "Built-in fallback while coach reconciliation completes."
           }),
         {:ok, _recommendation} <-
           Workouts.ensure_recommendation_selection_available(
             scope,
             recommendation.id
           ) do
      :ok
    end
  end

  defp schedule_scan(:infinity), do: :ok
  defp schedule_scan(interval_ms), do: Process.send_after(self(), :periodic_scan, interval_ms)
end
