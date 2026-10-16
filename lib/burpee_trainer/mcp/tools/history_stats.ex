defmodule BurpeeTrainer.Mcp.Tools.HistoryStats do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.{History, Workouts}
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.Sessions

  # Enough for any real history; stats read every matching session.
  @all 100_000

  def name, do: "history_stats"

  def description,
    do:
      "Totals per week (Monday first) or calendar month, with the same filters as " <>
        "query_history: sessions, minutes counted toward the week, reps, best reps per 20 " <>
        "minutes and average pace, overall and per burpee type. Weeks also say whether " <>
        "they met their minutes target. Numbers match the app's Progress screen."

  def schema,
    do:
      Tool.object(
        Map.put(Sessions.filter_schema(), "group_by", %{
          "type" => "string",
          "enum" => ~w[week month]
        }),
        ["group_by"]
      )

  def call(%{user: user} = scope, %{"group_by" => group_by} = args, _)
      when group_by in ~w[week month] do
    now = DateTime.utc_now()

    with [] <- Map.keys(args) -- ["group_by" | Sessions.filter_keys()],
         {:ok, filters} <- Sessions.filters(args, user, now),
         {rows, _more?} when is_list(rows) <-
           Workouts.list_sessions_page(scope, @all, filters: filters) do
      sessions = Sessions.authoritative(rows)
      targets = if group_by == "week", do: week_targets(scope, user, now), else: %{}

      periods =
        sessions
        |> Enum.group_by(&period_start(&1, group_by, user.timezone))
        |> Enum.sort_by(fn {start, _} -> start end, {:desc, Date})
        |> Enum.map(fn {start, in_period} ->
          totals(in_period)
          |> Map.merge(%{
            "start" => Date.to_iso8601(start),
            "by_type" =>
              in_period
              |> Enum.group_by(& &1.burpee_type)
              |> Enum.sort_by(fn {type, _} -> type end)
              |> Enum.map(fn {type, typed} ->
                Map.put(totals(typed), "burpee_type", to_string(type))
              end)
          })
          |> then(
            &if group_by == "week",
              do: Map.put(&1, "target_met", Map.get(targets, start, false)),
              else: &1
          )
        end)

      {:ok, %{"group_by" => group_by, "periods" => periods}}
    else
      unknown when is_list(unknown) -> {:error, "unknown arguments: #{Enum.join(unknown, ", ")}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "history is not available"}
    end
  end

  def call(_, _, _), do: {:error, "group_by must be week or month"}

  defp totals(sessions) do
    measured = History.points(Enum.reject(sessions, &(&1.tags == "warmup")))
    reps = measured |> Enum.map(& &1.actual_reps) |> Enum.sum()
    seconds = measured |> Enum.map(& &1.actual_duration_sec) |> Enum.sum()

    %{
      "sessions" => length(sessions),
      "minutes" => div(sessions |> Enum.map(&History.credited_seconds/1) |> Enum.sum(), 60),
      "reps" => reps,
      "best_reps_per_20_min" => measured |> Enum.map(& &1.density) |> Enum.max(fn -> nil end),
      "average_pace_sec" => if(reps > 0, do: Float.round(seconds / reps, 2))
    }
  end

  defp period_start(session, group_by, timezone) do
    date = session.completed_at |> Sessions.local_date(timezone) |> Date.from_iso8601!()
    if group_by == "week", do: Date.beginning_of_week(date), else: Date.beginning_of_month(date)
  end

  defp week_targets(scope, user, now) do
    case History.weeks(Workouts.list_sessions(scope), user, now, "all") do
      {:ok, weeks} -> Map.new(weeks, &{&1.start, &1.target?})
      _ -> %{}
    end
  end
end
