defmodule BurpeeTrainer.WeeklyTrainingContract do
  @moduledoc """
  Represents the app's fixed weekly training contract.

  The contract is status-only: it tracks completion against 4,800 seconds,
  80 minutes, 4 × 20 minute sessions, and a 2+2 type split. It does not
  schedule days, restore deviations, or optimize the week.
  """

  alias BurpeeTrainer.UserTime
  alias BurpeeTrainer.WeeklyTrainingContract.{Contract, PriorWeekResult, Slot, Status}

  @target_sec 4_800
  @target_min 80
  @standard_session_duration_sec 1_200
  @standard_session_duration_min 20
  @burpee_types [:six_count, :navy_seal]
  @prior_week_evidence_limit 12

  @spec contract() :: Contract.t()
  def contract do
    %Contract{
      target_sec: @target_sec,
      target_min: @target_min,
      standard_session_duration_min: @standard_session_duration_min,
      slots: [
        %Slot{burpee_type: :six_count, duration_min: @standard_session_duration_min},
        %Slot{burpee_type: :six_count, duration_min: @standard_session_duration_min},
        %Slot{burpee_type: :navy_seal, duration_min: @standard_session_duration_min},
        %Slot{burpee_type: :navy_seal, duration_min: @standard_session_duration_min}
      ]
    }
  end

  @spec status([struct()], Date.t(), String.t()) :: Status.t()
  def status(sessions, week_start_date, timezone \\ "Etc/UTC") do
    week_sessions =
      sessions |> non_warmup_sessions() |> sessions_in_week(week_start_date, timezone)

    completed_sec = Enum.reduce(week_sessions, 0, &(&2 + session_duration_sec(&1)))
    remaining_sec = max(@target_sec - completed_sec, 0)

    six_count = type_status(week_sessions, :six_count)
    navy_seal = type_status(week_sessions, :navy_seal)

    %Status{
      target_sec: @target_sec,
      completed_sec: completed_sec,
      remaining_sec: remaining_sec,
      target_min: @target_min,
      completed_min: div(completed_sec, 60),
      remaining_min: div(remaining_sec + 59, 60),
      six_count: six_count,
      navy_seal: navy_seal,
      status: status_atom(completed_sec, six_count, navy_seal)
    }
  end

  @spec prior_week_result([struct()], Date.t(), String.t()) :: PriorWeekResult.t()
  def prior_week_result(sessions, week_start_date, timezone \\ "Etc/UTC") do
    week_sessions =
      sessions |> non_warmup_sessions() |> sessions_in_week(week_start_date, timezone)

    completed_sec = Enum.reduce(week_sessions, 0, &(&2 + session_duration_sec(&1)))

    %PriorWeekResult{
      week_start: week_start_date,
      completed_sec: completed_sec,
      complete?: completed_sec >= @target_sec,
      workout_count: length(week_sessions),
      evidence_refs: prior_week_evidence_refs(week_sessions)
    }
  end

  @spec remaining_slots([struct()], Date.t()) :: [Slot.t()]
  def remaining_slots(sessions, week_start_date) do
    week_status = status(sessions, week_start_date)

    List.duplicate(
      %Slot{burpee_type: :six_count, duration_min: @standard_session_duration_min},
      week_status.six_count.remaining_standard_sessions
    ) ++
      List.duplicate(
        %Slot{burpee_type: :navy_seal, duration_min: @standard_session_duration_min},
        week_status.navy_seal.remaining_standard_sessions
      )
  end

  @spec remaining_minutes([struct()], Date.t()) :: non_neg_integer()
  def remaining_minutes(sessions, week_start_date),
    do: status(sessions, week_start_date).remaining_min

  @spec catch_up_available?(Date.t()) :: boolean()
  def catch_up_available?(%Date{} = today) do
    Date.day_of_week(today) in [6, 7]
  end

  defp non_warmup_sessions(sessions) do
    Enum.reject(sessions, &(Map.get(&1, :tags) == "warmup"))
  end

  defp sessions_in_week(sessions, week_start_date, timezone) do
    Enum.filter(sessions, fn session ->
      UserTime.in_week?(Map.get(session, :completed_at), week_start_date, timezone)
    end)
  end

  defp type_status(sessions, burpee_type) when burpee_type in @burpee_types do
    type_sessions = Enum.filter(sessions, &(&1.burpee_type == burpee_type))

    completed_sec = Enum.reduce(type_sessions, 0, &(&2 + session_duration_sec(&1)))

    completed_standard_sessions =
      Enum.count(type_sessions, &(session_duration_sec(&1) == @standard_session_duration_sec))

    target_sessions = 2

    %{
      target_sessions: target_sessions,
      completed_standard_sessions: completed_standard_sessions,
      completed_sec: completed_sec,
      completed_min: div(completed_sec, 60),
      remaining_standard_sessions: max(target_sessions - completed_standard_sessions, 0)
    }
  end

  defp session_duration_sec(%{duration_sec_actual: duration_sec}) when is_integer(duration_sec) do
    max(duration_sec, 0)
  end

  defp session_duration_sec(%{duration_sec_actual: duration_sec}) when is_float(duration_sec) do
    duration_sec
    |> max(0.0)
    |> round()
  end

  defp session_duration_sec(_session), do: 0

  defp status_atom(completed_sec, six_count, navy_seal) do
    canonical_complete? =
      six_count.completed_standard_sessions == 2 and navy_seal.completed_standard_sessions == 2

    non_standard? =
      completed_sec > 0 and
        (six_count.completed_sec !=
           six_count.completed_standard_sessions * @standard_session_duration_sec or
           navy_seal.completed_sec !=
             navy_seal.completed_standard_sessions * @standard_session_duration_sec)

    cond do
      completed_sec > @target_sec -> :over_target
      non_standard? -> :non_standard
      completed_sec == 0 -> :empty
      completed_sec == @target_sec and canonical_complete? -> :complete
      completed_sec < @target_sec -> :in_progress
      true -> :under_target
    end
  end

  defp prior_week_evidence_refs(week_sessions) do
    week_sessions
    |> Enum.filter(&positive_integer?(Map.get(&1, :id)))
    |> Enum.sort_by(&evidence_sort_key/1, :desc)
    |> Enum.take(@prior_week_evidence_limit)
    |> Enum.map(&%{kind: :session, id: &1.id})
  end

  defp evidence_sort_key(session) do
    {DateTime.to_unix(session.completed_at, :microsecond), Map.get(session, :id, 0)}
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
