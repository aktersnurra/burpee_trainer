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
end
