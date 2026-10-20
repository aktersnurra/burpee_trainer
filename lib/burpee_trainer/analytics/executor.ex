defmodule BurpeeTrainer.Analytics.Executor do
  @moduledoc "Tighten-only, bounded interface to isolated SQLite. Never opens the application DB."
  alias BurpeeTrainer.Analytics.{HelperGuardian, Snapshot}

  @errors ~w(executor_unavailable executor_busy sql_denied sql_error result_too_large query_timeout invalid_input)a

  def query(snapshot, sql, opts \\ [])

  def query(%Snapshot{schema_version: 1, rows: rows}, sql, opts)
      when is_binary(sql) and is_list(opts) do
    started = System.monotonic_time(:millisecond)
    timeout = if Keyword.keyword?(opts), do: Keyword.get(opts, :timeout_ms, 1000), else: nil

    with true <- valid_request?(rows, sql, timeout, opts),
         {:ok, data} <- Jason.encode(%{version: 1, rows: rows, sql: sql}),
         true <- byte_size(data) <= 2_097_152,
         {:ok, output} <- HelperGuardian.query(<<byte_size(data)::32, data::binary>>, timeout),
         {:ok, result} <- decode(output) do
      {:ok, Map.put(result, :duration_ms, System.monotonic_time(:millisecond) - started)}
    else
      {:error, code} when code in @errors -> {:error, code}
      _ -> {:error, :invalid_input}
    end
  end

  def query(_snapshot, _sql, _opts), do: {:error, :invalid_input}

  defp valid_request?(rows, sql, timeout, opts) do
    is_integer(timeout) and timeout in 1..1000 and
      Keyword.keys(opts) -- [:timeout_ms] == [] and
      valid_sql?(sql) and valid_snapshot_rows?(rows)
  end

  defp valid_sql?(sql),
    do: byte_size(sql) in 1..4096 and String.valid?(sql) and not String.contains?(sql, <<0>>)

  defp valid_snapshot_rows?(rows) do
    is_list(rows) and Enum.count_until(rows, 5001) <= 5000 and Enum.all?(rows, &valid_row?/1) and
      byte_size(Jason.encode!(rows)) <= 1_048_576
  end

  defp valid_row?([
         id,
         completed_at,
         local_date,
         source,
         burpee_type,
         capture,
         reps,
         planned_reps,
         duration,
         planned_duration,
         credited,
         warmup,
         pace,
         normalized
       ]) do
    valid_identity?(id, completed_at, local_date, source, burpee_type, capture) and
      warmup in [0, 1] and is_integer(credited) and nullable_integer?(credited) and
      Enum.all?(
        [reps, planned_reps, duration, planned_duration, normalized],
        &nullable_integer?/1
      ) and
      (is_nil(pace) or is_float(pace))
  end

  defp valid_row?(_row), do: false

  defp valid_identity?(id, completed_at, local_date, source, burpee_type, capture) do
    is_integer(id) and id > 0 and nullable_integer?(id) and short_text?(completed_at) and
      short_text?(local_date) and source in ~w(plan video manual) and
      burpee_type in ~w(six_count navy_seal) and capture in ~w(tracked timed logged)
  end

  defp short_text?(value),
    do: is_binary(value) and byte_size(value) <= 128 and String.valid?(value)

  defp nullable_integer?(value),
    do:
      is_nil(value) or
        (is_integer(value) and value >= -9_223_372_036_854_775_808 and
           value <= 9_223_372_036_854_775_807)

  defp decode(output) when byte_size(output) <= 8192 do
    case Jason.decode(output) do
      {:ok, %{"version" => 1, "ok" => true, "columns" => columns, "rows" => rows} = response}
      when map_size(response) == 4 ->
        if valid_result?(columns, rows),
          do: {:ok, %{columns: columns, rows: rows}},
          else: {:error, :executor_unavailable}

      {:ok, %{"version" => 1, "ok" => false, "code" => code} = response}
      when map_size(response) == 3 ->
        {:error, Enum.find(@errors, :executor_unavailable, &(Atom.to_string(&1) == code))}

      _ ->
        {:error, :executor_unavailable}
    end
  end

  defp decode(_output), do: {:error, :executor_unavailable}

  defp valid_result?(columns, rows) do
    valid_columns?(columns) and is_list(rows) and Enum.count_until(rows, 101) <= 100 and
      Enum.all?(rows, fn row ->
        is_list(row) and length(row) == length(columns) and Enum.all?(row, &scalar?/1)
      end)
  end

  defp valid_columns?(columns) do
    is_list(columns) and length(columns) in 1..16 and
      Enum.all?(columns, &(is_binary(&1) and byte_size(&1) <= 1024)) and
      Enum.uniq(columns) == columns
  end

  defp scalar?(value) when is_binary(value), do: byte_size(value) <= 1024

  defp scalar?(value) do
    (is_nil(value) or is_integer(value) or is_float(value)) and
      byte_size(Jason.encode!(value)) <= 1024
  end
end
