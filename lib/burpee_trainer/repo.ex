defmodule BurpeeTrainer.Repo do
  use Ecto.Repo,
    otp_app: :burpee_trainer,
    adapter: Ecto.Adapters.SQLite3

  @immediate_transaction_retry_delay_ms 50
  @immediate_transaction_retry_attempts 40

  def immediate_transaction(fun_or_multi, opts \\ []) do
    opts = Keyword.put_new(opts, :mode, :immediate)
    do_immediate_transaction(fun_or_multi, opts, @immediate_transaction_retry_attempts)
  end

  defp do_immediate_transaction(fun_or_multi, opts, attempts_left) do
    with :ok <- admission_check(opts) do
      transaction_opts = Keyword.drop(opts, [:deadline_ms, :admission_check])
      transaction_opts = Keyword.put(transaction_opts, :timeout, remaining_timeout(opts))
      transaction(checked_transaction(fun_or_multi, opts), transaction_opts)
    end
  rescue
    error in Exqlite.Error ->
      if attempts_left > 0 and sqlite_busy_on_begin?(error) do
        Process.sleep(min(@immediate_transaction_retry_delay_ms, remaining_timeout(opts)))
        do_immediate_transaction(fun_or_multi, opts, attempts_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  # Deadline-enabled admission checks both sides of the transaction body, including
  # after acquiring SQLite's write lock. A cancelled/expired insert is rolled back.
  defp checked_transaction(fun, opts) when is_function(fun, 0) do
    fn ->
      check_or_rollback(opts)
      result = fun.()
      check_or_rollback(opts)
      result
    end
  end

  defp checked_transaction(multi, _opts), do: multi

  defp check_or_rollback(opts) do
    case admission_check(opts) do
      :ok -> :ok
      {:error, reason} -> rollback(reason)
    end
  end

  defp admission_check(opts) do
    check = Keyword.get(opts, :admission_check, fn -> :ok end)

    with :ok <- check.(), do: check_deadline(Keyword.get(opts, :deadline_ms))
  end

  defp check_deadline(nil), do: :ok

  defp check_deadline(deadline) do
    if deadline > System.monotonic_time(:millisecond),
      do: :ok,
      else: {:error, :deadline_exceeded}
  end

  defp remaining_timeout(opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    case Keyword.get(opts, :deadline_ms) do
      nil -> timeout
      deadline -> max(1, min(timeout, deadline - System.monotonic_time(:millisecond)))
    end
  end

  defp sqlite_busy_on_begin?(%Exqlite.Error{message: message}) when is_binary(message) do
    String.contains?(message, "database is locked")
  end

  defp sqlite_busy_on_begin?(_error), do: false
end
