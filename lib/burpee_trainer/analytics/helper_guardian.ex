defmodule BurpeeTrainer.Analytics.HelperGuardian do
  @moduledoc "Independent owner of at most two sandbox launchers; no admission queue."
  use GenServer

  @name __MODULE__
  @max_output 8192

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def query(frame, timeout) do
    GenServer.call(@name, {:query, frame, timeout}, 2500)
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

  def handle_call({:query, _frame, _timeout}, _from, %{healthy: false} = state),
    do: {:reply, {:error, :executor_unavailable}, state}

  def handle_call({:query, frame, timeout}, from, state) do
    if map_size(state.active) >= 2 do
      {:reply, {:error, :executor_busy}, state}
    else
      admit(frame, timeout, from, state)
    end
  end

  defp admit(frame, timeout, {caller, _tag} = from, state) do
    case launch(frame) do
      {:ok, port} ->
        monitor = Process.monitor(caller)
        timer = Process.send_after(self(), {:deadline, port}, timeout)
        entry = %{from: from, monitor: monitor, timer: timer, output: <<>>, error: nil}
        {:noreply, put_in(state.active[port], entry)}

      :error ->
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

  def handle_info({port, {:exit_status, status}}, state) do
    case Map.pop(state.active, port) do
      {nil, _active} ->
        {:noreply, state}

      {entry, active} ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(entry.monitor, [:flush])
        result = complete(entry, status)
        GenServer.reply(entry.from, result)
        {:noreply, %{state | active: active}}
    end
  end

  def handle_info({:deadline, port}, state),
    do: {:noreply, cancel(state, port, :query_timeout)}

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

  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.active, fn {port, _entry} -> kill_launcher(port) end)
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
    Port.command(port, frame)
  rescue
    ArgumentError -> false
  end

  defp complete(%{error: error}, _status) when not is_nil(error), do: {:error, error}
  defp complete(%{output: output}, 0), do: {:ok, output}
  defp complete(_entry, _status), do: {:error, :executor_unavailable}

  defp launch(frame) do
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

      if safe_command(port, frame), do: {:ok, port}, else: :error
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

    case launch(<<byte_size(data)::32, data::binary>>) do
      {:ok, port} ->
        output = probe_output(port, <<>>, System.monotonic_time(:millisecond) + 1000)
        match?({:ok, %{"version" => 1, "ok" => ^expected}}, Jason.decode(output))

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
