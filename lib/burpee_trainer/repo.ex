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
    transaction(fun_or_multi, opts)
  rescue
    error in Exqlite.Error ->
      if attempts_left > 0 and sqlite_busy_on_begin?(error) do
        Process.sleep(@immediate_transaction_retry_delay_ms)
        do_immediate_transaction(fun_or_multi, opts, attempts_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp sqlite_busy_on_begin?(%Exqlite.Error{message: message}) when is_binary(message) do
    String.contains?(message, "database is locked")
  end

  defp sqlite_busy_on_begin?(_error), do: false
end
