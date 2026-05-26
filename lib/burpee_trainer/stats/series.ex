defmodule BurpeeTrainer.Stats.Series do
  @moduledoc """
  Pure chart data shaping for stats screens.
  """

  @type weekly_row :: %{week_start: Date.t(), minutes: number()}
  @type weekly_point :: %{week_start: Date.t(), minutes: number()}
  @type weekly_model :: %{points: [weekly_point()], max_minutes: number()}

  @spec weekly_minutes([weekly_row()]) :: weekly_model()
  def weekly_minutes(rows) do
    points = Enum.sort_by(rows, & &1.week_start, Date)
    max_minutes = points |> Enum.map(& &1.minutes) |> Enum.max(fn -> 0 end)

    %{points: points, max_minutes: max_minutes}
  end

  @type progress_session :: %{
          inserted_at: DateTime.t(),
          burpee_count_actual: pos_integer(),
          duration_sec_actual: pos_integer()
        }

  @type progress_point :: %{
          inserted_at: DateTime.t(),
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
      |> Enum.sort_by(& &1.inserted_at, DateTime)
      |> Enum.map(fn session ->
        count = session.burpee_count_actual || 0
        duration = session.duration_sec_actual || 0
        pace = if count > 0, do: duration / count, else: 0.0

        %{inserted_at: session.inserted_at, burpee_count: count, sec_per_burpee: pace}
      end)

    paces = Enum.map(points, & &1.sec_per_burpee)

    %{
      points: points,
      max_count: points |> Enum.map(& &1.burpee_count) |> Enum.max(fn -> 0 end),
      min_pace: if(paces == [], do: nil, else: Enum.min(paces)),
      max_pace: if(paces == [], do: nil, else: Enum.max(paces))
    }
  end
end
