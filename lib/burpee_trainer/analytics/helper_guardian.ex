defmodule BurpeeTrainer.Analytics.HelperGuardian do
  @moduledoc "Independent owner of at most two sandbox launchers; no admission queue."
  use GenServer

  @name __MODULE__
  @max_output 8192

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def query(frame, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(@name, {:query, frame, deadline}, 2500)
  catch
    :exit, _reason -> {:error, :executor_unavailable}
  end

  def health, do: GenServer.call(@name, :health)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{healthy: probe(), active: %{}}}
  end

  @impl true
  def handle_call(:health, _from, state), do: {:reply, state.healthy, state}

  def handle_call({:query, _frame, _deadline}, _from, %{healthy: false} = state),
    do: {:reply, {:error, :executor_unavailable}, state}

  def handle_call({:query, frame, deadline}, from, state) do
    cond do
      deadline <= System.monotonic_time(:millisecond) ->
        {:reply, {:error, :query_timeout}, state}

      map_size(state.active) >= 2 ->
        {:reply, {:error, :executor_busy}, state}

      true ->
        admit(frame, deadline, from, state)
    end
  end

  defp admit(frame, deadline, {caller, _tag} = from, state) do
    token = make_ref()
    monitor = Process.monitor(caller)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    timer = Process.send_after(self(), {:deadline, token}, remaining)

    case launch() do
      {:ok, port} ->
        entry = %{
          from: from,
          monitor: monitor,
          timer: timer,
          token: token,
          deadline: deadline,
          pending: frame,
          output: <<>>,
          error: nil
        }

        send(self(), {:submit, port})
        {:noreply, put_in(state.active[port], entry)}

      :error ->
        Process.cancel_timer(timer)
        Process.demonitor(monitor, [:flush])
        {:reply, {:error, :executor_unavailable}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) do
    case state.active do
      %{^port => entry} ->
        if byte_size(entry.output) + byte_size(data) > @max_output do
          {:noreply, cancel(state, port, :executor_unavailable)}
        else
          {:noreply, put_in(state.active[port].output, entry.output <> data)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state),
    do: {:noreply, finish(state, port, status)}

  def handle_info({:deadline, token}, state) do
    case Enum.find(state.active, fn {_port, entry} -> entry.token == token end) do
      {port, _entry} -> {:noreply, cancel(state, port, :query_timeout)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:submit, port}, state) do
    case state.active do
      %{^port => %{error: nil, pending: pending} = entry} when pending != <<>> ->
        {:noreply, submit(state, port, entry)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.active, state, fn {port, entry}, acc ->
        if entry.monitor == monitor, do: cancel(acc, port, :query_timeout), else: acc
      end)

    {:noreply, state}
  end

  def handle_info({:force_kill, port}, state) do
    if Map.has_key?(state.active, port), do: kill_launcher(port)
    {:noreply, state}
  end

  # Killing a launcher with pending stdin may close its port with :epipe instead
  # of delivering :exit_status. Finish that cancellation rather than leaking admission.
  def handle_info({:EXIT, port, _reason}, state), do: {:noreply, finish(state, port, 1)}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.active, fn {port, _entry} -> kill_launcher(port) end)
  end

  defp finish(state, port, status) do
    case Map.pop(state.active, port) do
      {nil, _active} ->
        state

      {entry, active} ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(entry.monitor, [:flush])
        result = complete(entry, status, System.monotonic_time(:millisecond))
        GenServer.reply(entry.from, result)
        %{state | active: active}
    end
  end

  defp submit(state, port, entry) do
    if System.monotonic_time(:millisecond) >= entry.deadline do
      cancel(state, port, :query_timeout)
    else
      submit_chunk(state, port, entry.pending)
    end
  end

  defp submit_chunk(state, port, pending) do
    size = min(byte_size(pending), 4096)
    <<chunk::binary-size(^size), rest::binary>> = pending

    if safe_command(port, chunk) do
      if rest != <<>>, do: send(self(), {:submit, port})
      put_in(state.active[port].pending, rest)
    else
      Process.send_after(self(), {:submit, port}, 1)
      state
    end
  end

  defp cancel(state, port, error) do
    case state.active do
      %{^port => %{error: nil}} ->
        # Any post-frame input is cancellation. The launcher SIGKILLs and reaps bwrap
        # before responding. SIGKILL of the launcher is the independent backstop;
        # bwrap's --die-with-parent kills the namespace if the launcher itself dies.
        safe_command(port, <<0>>)
        Process.send_after(self(), {:force_kill, port}, 100)
        put_in(state.active[port].error, error)

      _ ->
        state
    end
  end

  defp kill_launcher(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("/usr/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end
  end

  defp safe_command(port, frame) do
    # Never suspend the shared watchdog on a busy external process's input pipe.
    Port.command(port, frame, [:nosuspend])
  rescue
    ArgumentError -> false
  end

  defp complete(%{error: error}, _status, _now) when not is_nil(error), do: {:error, error}

  defp complete(%{deadline: deadline}, _status, now) when now >= deadline,
    do: {:error, :query_timeout}

  defp complete(%{output: output}, 0, _now), do: {:ok, output}
  defp complete(_entry, _status, _now), do: {:error, :executor_unavailable}

  defp launch do
    path = Application.app_dir(:burpee_trainer, "priv/analytics/helper_launcher.py")

    with true <- trusted?(path),
         true <- trusted?("/usr/bin/python3"),
         true <- trusted?("/usr/bin/kill") do
      env = Enum.map(System.get_env(), fn {key, _value} -> {String.to_charlist(key), false} end)

      port =
        Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:env, env},
          {:args, [~c"-I", String.to_charlist(path), String.to_charlist(System.pid())]}
        ])

      {:ok, port}
    else
      _ -> :error
    end
  rescue
    _error in [ArgumentError, ErlangError] -> :error
  end

  defp trusted?(path) do
    with {:ok, %{type: :regular}} <- File.stat(path),
         {:ok, %{uid: uid}} <- File.stat("/proc/self") do
      Enum.all?([path | ancestors(path)], &trusted_owner?(&1, uid))
    else
      _ -> false
    end
  end

  defp ancestors("/"), do: []
  defp ancestors(path), do: [Path.dirname(path) | ancestors(Path.dirname(path))]

  defp trusted_owner?(path, uid) do
    case File.stat(path) do
      {:ok, %{uid: owner, mode: mode}} -> owner in [0, uid] and Bitwise.band(mode, 0o022) == 0
      _ -> false
    end
  end

  defp probe do
    Enum.all?(
      [
        {"SELECT count(*) AS n FROM sessions", true},
        {"ATTACH ':memory:' AS other", false},
        {"SELECT randomblob(1)", false},
        {"SELECT 1; SELECT 2", false}
      ],
      fn {sql, expected} -> probe_query(sql, expected) end
    )
  end

  defp probe_query(sql, expected) do
    data = Jason.encode!(%{version: 1, rows: [], sql: sql})

    deadline = System.monotonic_time(:millisecond) + 1000

    case launch() do
      {:ok, port} ->
        if safe_command(port, <<byte_size(data)::32, data::binary>>) do
          output = probe_output(port, <<>>, deadline)
          match?({:ok, %{"version" => 1, "ok" => ^expected}}, Jason.decode(output))
        else
          kill_launcher(port)
          false
        end

      :error ->
        false
    end
  end

  defp probe_output(port, output, deadline) do
    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= @max_output ->
        probe_output(port, output <> data, deadline)

      {^port, {:exit_status, 0}} ->
        output

      {^port, _other} ->
        kill_launcher(port)
        <<>>
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        kill_launcher(port)
        <<>>
    end
  end
end
