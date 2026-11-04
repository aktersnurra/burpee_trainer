defmodule BurpeeTrainer.Mcp.Tools.QueryHistory do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.{HistoryContext, Sessions}
  alias BurpeeTrainer.Workouts

  @max_limit 100

  def name, do: "query_history"

  def description,
    do:
      "Completed sessions, newest first, matching all the filters given. Each has reps and " <>
        "minutes (planned and done), elapsed and active pace, reps per 20 minutes, pace " <>
        "consistency, sets completed, mood, limiter, preference, energy and heat, tags and " <>
        "notes, and for camera sessions fatigue and window slack. include_sets adds each " <>
        "set's window, reps and rep times. `fields` gives each field's unit and meaning; " <>
        "burpee://fatigue-guide defines fatigue, sets and slack. Pass next_cursor back as " <>
        "cursor for the next page; get_session reads one session by id."

  def schema,
    do:
      Tool.object(
        Map.merge(Sessions.filter_schema(), %{
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_limit,
            "default" => 50
          },
          "cursor" => %{"type" => "string"},
          "include_sets" => %{
            "type" => "boolean",
            "default" => false,
            "description" => "Add each camera session's sets: windows, reps and rep times."
          }
        }),
        []
      )

  def call(%{user: user} = scope, args, _) when is_map(args) do
    now = DateTime.utc_now()
    known = ["limit", "cursor", "include_sets" | Sessions.filter_keys()]

    with [] <- Map.keys(args) -- known,
         {:ok, limit} <- limit(Map.get(args, "limit", 50)),
         {:ok, sets?} <- include_sets(Map.get(args, "include_sets", false)),
         {:ok, cursor} <- Sessions.decode_cursor(Map.get(args, "cursor")),
         {:ok, filters} <- Sessions.filters(args, user, now) do
      opts = [filters: filters] ++ if(cursor, do: [before: cursor], else: [])

      case Workouts.list_sessions_page(scope, limit, opts) do
        {rows, more?} when is_list(rows) ->
          sessions = Sessions.authoritative(rows)
          next = if more?, do: rows |> List.last() |> then(&{&1.completed_at, &1.id})

          {:ok,
           %{
             "sessions" => Enum.map(sessions, &Sessions.encode(&1, user.timezone, sets: sets?)),
             "fields" => Sessions.fields(),
             "next_cursor" => Sessions.encode_cursor(next),
             "context" =>
               HistoryContext.build(
                 args,
                 user,
                 filters,
                 length(sessions),
                 length(rows) - length(sessions),
                 more?: more?,
                 cursor?: cursor != nil
               )
           }}

        {:error, _} ->
          {:error, "invalid cursor"}
      end
    else
      unknown when is_list(unknown) -> {:error, "unknown arguments: #{Enum.join(unknown, ", ")}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_, _, _), do: {:error, "query_history takes filters as an object"}

  defp include_sets(value) when is_boolean(value), do: {:ok, value}
  defp include_sets(_), do: {:error, "include_sets must be true or false"}

  defp limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: {:ok, limit}
  defp limit(_), do: {:error, "limit must be 1 to #{@max_limit}"}
end
