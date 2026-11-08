defmodule BurpeeTrainer.Stats.Series do
  @moduledoc """
  Pure chart data shaping for stats screens.
  """

  alias BurpeeTrainer.Coach.Endurance

  @type progress_session :: %{
          completed_at: DateTime.t(),
          burpee_count_actual: pos_integer(),
          duration_sec_actual: pos_integer()
        }

  @type progress_point :: %{
          completed_at: DateTime.t(),
          burpee_count: non_neg_integer(),
          sec_per_burpee: float()
        }

  @type progress_model :: %{
          points: [progress_point()],
          max_count: non_neg_integer(),
          min_pace: float() | nil,
          max_pace: float() | nil
        }

  @spec progress([progress_session()]) :: progress_model()
  def progress(sessions) do
    points =
      sessions
      |> Enum.sort_by(& &1.completed_at, DateTime)
      |> Enum.map(fn session ->
        count = session.burpee_count_actual || 0
        duration = session.duration_sec_actual || 0
        pace = if count > 0, do: duration / count, else: 0.0

        {_year, iso_week} =
          :calendar.iso_week_number(Date.to_erl(DateTime.to_date(session.completed_at)))

        normalized_reps = normalized_reps(count, duration)

        %{
          completed_at: session.completed_at,
          burpee_count: count,
          sec_per_burpee: pace,
          normalized_reps: normalized_reps,
          iso_week: iso_week
        }
      end)

    paces = Enum.map(points, & &1.sec_per_burpee)

    %{
      points: points,
      max_count: points |> Enum.map(& &1.burpee_count) |> Enum.max(fn -> 0 end),
      min_pace: if(paces == [], do: nil, else: Enum.min(paces)),
      max_pace: if(paces == [], do: nil, else: Enum.max(paces))
    }
  end

  # Reps per 20 minutes. A shorter session scales up in proportion; a longer one reads as the
  # 20-minute session it is as good as, fatigue counted (forty minutes holds 1.5 times).
  defp normalized_reps(_count, duration) when duration <= 0, do: 0

  defp normalized_reps(count, duration) when duration <= 1200,
    do: round(count / duration * 1200.0)

  defp normalized_reps(count, duration), do: round(count / Endurance.factor(duration))
end
