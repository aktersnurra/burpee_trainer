defmodule BurpeeTrainer.Mcp.Tools.QueryHistory do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.Sessions
  alias BurpeeTrainer.Workouts

  @max_limit 100

  def name, do: "query_history"

  def description,
    do:
      "Completed sessions, newest first, matching all the filters given. Each has reps and " <>
        "minutes (planned and done), pace, reps per 20 minutes, pace consistency, sets " <>
        "completed, mood, limiter, preference, energy and heat, tags and notes. Pass " <>
        "next_cursor back as cursor for the next page."

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
          "cursor" => %{"type" => "string"}
        }),
        []
      )

  def call(%{user: user} = scope, args, _) when is_map(args) do
    known = ["limit", "cursor" | Sessions.filter_keys()]

    with [] <- Map.keys(args) -- known,
         {:ok, limit} <- limit(Map.get(args, "limit", 50)),
         {:ok, cursor} <- Sessions.decode_cursor(Map.get(args, "cursor")),
         {:ok, filters} <- Sessions.filters(args, user, DateTime.utc_now()) do
      opts = [filters: filters] ++ if(cursor, do: [before: cursor], else: [])

      case Workouts.list_sessions_page(scope, limit, opts) do
        {rows, more?} when is_list(rows) ->
          next = if more?, do: rows |> List.last() |> then(&{&1.completed_at, &1.id})

          {:ok,
           %{
             "sessions" =>
               rows |> Sessions.authoritative() |> Enum.map(&Sessions.encode(&1, user.timezone)),
             "next_cursor" => Sessions.encode_cursor(next)
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

  defp limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: {:ok, limit}
  defp limit(_), do: {:error, "limit must be 1 to #{@max_limit}"}
end
