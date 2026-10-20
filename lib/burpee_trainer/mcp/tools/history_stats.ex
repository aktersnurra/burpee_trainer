defmodule BurpeeTrainer.Mcp.Tools.HistoryStats do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.{History, Workouts}
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.{HistoryContext, HistoryCoverage, HistorySummary, Sessions}

  def name, do: "history_stats"

  def description,
    do:
      "Complete range summary with optional day, week (Monday first), or month periods. " <>
        "Actual seconds and reps, weekly credit, measurement coverage and per-type weighted pace. " <>
        "Weekly targets describe whole-week, all-type history, not the filtered cohort. " <>
        "See burpee://analytics-guide for comparability and completeness rules."

  def schema,
    do:
      Tool.object(
        Map.put(Sessions.filter_schema(), "group_by", %{
          "type" => "string",
          "enum" => ~w[range day week month],
          "default" => "range"
        }),
        []
      )

  def call(%{user: user} = scope, args, _) when is_map(args) do
    now = DateTime.utc_now()
    group_by = Map.get(args, "group_by", "range")

    with [] <- Map.keys(args) -- ["group_by" | Sessions.filter_keys()],
         :ok <- validate_group(group_by),
         {:ok, filters} <- Sessions.filters(args, user, now),
         {:ok, rows} <- HistoryCoverage.fetch(scope, filters),
         sessions = Sessions.authoritative(rows),
         {:ok, summary} <- HistorySummary.summarize(sessions, user.timezone) do
      targets = if group_by == "week", do: week_targets(scope, user, now), else: %{}

      {:ok,
       %{
         "group_by" => group_by,
         "summary" => summary,
         "periods" => periods(sessions, group_by, user.timezone, filters, targets),
         "context" =>
           HistoryContext.build(
             args,
             user,
             filters,
             length(sessions),
             length(rows) - length(sessions),
             false,
             false
           )
       }}
    else
      unknown when is_list(unknown) -> {:error, "unknown arguments: #{Enum.join(unknown, ", ")}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "history is not available"}
    end
  end

  def call(_, _, _), do: {:error, "history_stats takes filters as an object"}

  defp validate_group(group) when group in ~w[range day week month], do: :ok
  defp validate_group(_), do: {:error, "group_by must be range, day, week or month"}

  defp periods(_, "range", _, _, _), do: []

  defp periods(sessions, group, timezone, filters, targets) do
    sessions
    |> Enum.group_by(&period_start(&1, group, timezone))
    |> Enum.sort_by(fn {start, _} -> start end, {:desc, Date})
    |> Enum.map(fn {start, selected} ->
      {:ok, summary} = HistorySummary.summarize(selected, timezone)
      finish = period_end(start, group)

      summary
      |> Map.merge(%{
        "start" => Date.to_iso8601(start),
        "end" => Date.to_iso8601(finish),
        "partial" => HistoryContext.partial?(start, finish, filters, timezone)
      })
      |> add_target(group, targets[start])
    end)
  end

  defp add_target(summary, "week", target) do
    Map.merge(summary, %{
      "target_met" => target != nil and target.target?,
      "target_seconds" => if(target, do: target.target_minutes * 60),
      "target_scope" => "whole_week_all_types_unfiltered_owner_history"
    })
  end

  defp add_target(summary, _, _), do: summary

  defp period_start(session, group, timezone) do
    date = session.completed_at |> Sessions.local_date(timezone) |> Date.from_iso8601!()

    case group do
      "day" -> date
      "week" -> Date.beginning_of_week(date)
      "month" -> Date.beginning_of_month(date)
    end
  end

  defp period_end(start, "day"), do: start
  defp period_end(start, "week"), do: Date.end_of_week(start)
  defp period_end(start, "month"), do: Date.end_of_month(start)

  defp week_targets(scope, user, now) do
    case History.weeks(Workouts.list_sessions(scope), user, now, "all") do
      {:ok, weeks} -> Map.new(weeks, &{&1.start, &1})
      _ -> %{}
    end
  end
end
