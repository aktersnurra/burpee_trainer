defmodule BurpeeTrainer.Analytics.Snapshot do
  @moduledoc "Bounded immutable owner projection, read in one database transaction."

  import Ecto.Query
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.AuthoritativeSession
  alias BurpeeTrainer.{History, Repo, UserTime}
  alias BurpeeTrainer.Workouts.WorkoutSession

  defstruct rows: [], as_of: nil, timezone: nil, schema_version: 1

  @type t :: %__MODULE__{
          rows: [[term()]],
          as_of: DateTime.t() | nil,
          timezone: String.t() | nil,
          schema_version: 1
        }

  def build(scope, opts \\ [])

  def build(%Scope{user: %{id: id, timezone: timezone} = user}, opts)
      when is_integer(id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with %DateTime{} <- now,
         true <- is_binary(timezone),
         {:ok, _context} <- UserTime.context(user, now) do
      build_transaction(id, now, timezone)
    else
      _ -> {:error, :invalid_timezone}
    end
  end

  def build(_scope, _opts), do: {:error, :invalid_input}

  defp build_transaction(id, now, timezone) do
    case Repo.transaction(fn -> read_rows(id, now, timezone) end) do
      {:ok, rows} -> {:ok, %__MODULE__{rows: rows, as_of: now, timezone: timezone}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_rows(id, now, timezone) do
    candidates =
      Repo.all(
        from(s in WorkoutSession,
          where: s.user_id == ^id and s.state == :completed and s.completed_at <= ^now,
          order_by: [asc: s.completed_at, asc: s.id],
          limit: 5001
        )
      )

    if Enum.count_until(candidates, 5001) > 5000, do: Repo.rollback(:snapshot_too_large)

    rows =
      candidates
      |> Enum.filter(&AuthoritativeSession.authoritative?/1)
      |> Enum.map(&project(&1, timezone))

    unless Enum.all?(rows, &representable?/1), do: Repo.rollback(:invalid_snapshot)
    if byte_size(Jason.encode!(rows)) > 1_048_576, do: Repo.rollback(:snapshot_too_large)
    rows
  end

  defp project(session, timezone) do
    {:ok, local_date} = UserTime.local_date(session.completed_at, timezone)
    {pace, normalized} = actual_metrics(session)

    [
      session.id,
      DateTime.to_iso8601(session.completed_at),
      Date.to_iso8601(local_date),
      to_string(session.source_kind),
      to_string(session.burpee_type),
      to_string(session.capture_mode),
      actual(session.burpee_count_actual),
      session.burpee_count_planned,
      actual(session.duration_sec_actual),
      session.duration_sec_planned,
      History.credited_seconds(session),
      if(session.tags == "warmup", do: 1, else: 0),
      pace,
      normalized
    ]
  end

  defp actual(value) when is_integer(value) and value >= 0, do: value
  defp actual(_value), do: nil

  defp representable?(row) do
    row
    |> Enum.with_index()
    |> Enum.all?(fn
      {value, index} when index in [0, 6, 7, 8, 9, 10, 11, 13] ->
        is_nil(value) or
          (is_integer(value) and value >= -9_223_372_036_854_775_808 and
             value <= 9_223_372_036_854_775_807)

      _ ->
        true
    end)
  end

  defp actual_metrics(%{burpee_count_actual: reps, duration_sec_actual: seconds})
       when is_integer(reps) and reps > 0 and is_integer(seconds) and seconds > 0,
       do: {seconds / reps, round(reps / seconds * 1200.0)}

  defp actual_metrics(_session), do: {nil, nil}
end
