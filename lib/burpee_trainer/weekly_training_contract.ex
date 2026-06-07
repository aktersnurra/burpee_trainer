defmodule BurpeeTrainer.WeeklyTrainingContract do
  @moduledoc """
  Represents the app's fixed weekly training contract.

  The contract is status-only: it tracks completion against 80 minutes,
  4 × 20 minute sessions, and a 2+2 type split. It does not schedule days,
  repair deviations, or optimize the week.
  """

  alias BurpeeTrainer.WeeklyTrainingContract.{Contract, Slot, Status}

  @target_min 80
  @standard_session_duration_min 20
  @burpee_types [:six_count, :navy_seal]

  @spec contract() :: Contract.t()
  def contract do
    %Contract{
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

  @spec status([struct()], Date.t()) :: Status.t()
  def status(sessions, week_start_date) do
    week_sessions = sessions |> non_warmup_sessions() |> sessions_in_week(week_start_date)
    completed_min = Enum.reduce(week_sessions, 0, &(&2 + session_duration_min(&1)))
    remaining_min = max(@target_min - completed_min, 0)

    six_count = type_status(week_sessions, :six_count)
    navy_seal = type_status(week_sessions, :navy_seal)

    %Status{
      target_min: @target_min,
      completed_min: completed_min,
      remaining_min: remaining_min,
      six_count: six_count,
      navy_seal: navy_seal,
      status: status_atom(completed_min, six_count, navy_seal)
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

  defp sessions_in_week(sessions, week_start_date) do
    week_end = Date.add(week_start_date, 7)

    Enum.filter(sessions, fn session ->
      case session_date(session) do
        nil -> false
        date -> Date.compare(date, week_start_date) != :lt and Date.compare(date, week_end) == :lt
      end
    end)
  end

  defp session_date(%{inserted_at: %DateTime{} = inserted_at}), do: DateTime.to_date(inserted_at)

  defp session_date(%{inserted_at: %NaiveDateTime{} = inserted_at}),
    do: NaiveDateTime.to_date(inserted_at)

  defp session_date(%{inserted_at: %Date{} = inserted_at}), do: inserted_at
  defp session_date(_session), do: nil

  defp type_status(sessions, burpee_type) when burpee_type in @burpee_types do
    type_sessions = Enum.filter(sessions, &(&1.burpee_type == burpee_type))

    completed_min = Enum.reduce(type_sessions, 0, &(&2 + session_duration_min(&1)))

    completed_standard_sessions =
      Enum.count(type_sessions, &(session_duration_min(&1) == @standard_session_duration_min))

    target_sessions = 2

    %{
      target_sessions: target_sessions,
      completed_standard_sessions: completed_standard_sessions,
      completed_min: completed_min,
      remaining_standard_sessions: max(target_sessions - completed_standard_sessions, 0)
    }
  end

  defp session_duration_min(%{duration_sec_actual: duration_sec}) when is_integer(duration_sec) do
    round(duration_sec / 60)
  end

  defp session_duration_min(%{duration_sec_actual: duration_sec}) when is_float(duration_sec) do
    round(duration_sec / 60)
  end

  defp session_duration_min(_session), do: 0

  defp status_atom(completed_min, six_count, navy_seal) do
    canonical_complete? =
      six_count.completed_standard_sessions == 2 and navy_seal.completed_standard_sessions == 2

    non_standard? =
      completed_min > 0 and
        (six_count.completed_min !=
           six_count.completed_standard_sessions * @standard_session_duration_min or
           navy_seal.completed_min !=
             navy_seal.completed_standard_sessions * @standard_session_duration_min)

    cond do
      completed_min > @target_min -> :over_target
      non_standard? -> :non_standard
      completed_min == 0 -> :empty
      completed_min == @target_min and canonical_complete? -> :complete
      completed_min < @target_min -> :in_progress
      true -> :under_target
    end
  end
end
