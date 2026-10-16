defmodule BurpeeTrainer.Coach.Tools.History do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Tool, AuthoritativeSession}
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Accounts.Scope}
  alias BurpeeTrainer.Workouts.WorkoutSession
  def name, do: "history"
  def description, do: "Completed session summaries for 1 to 26 weeks."

  def schema,
    do:
      Tool.object(%{"weeks" => %{"type" => "integer", "minimum" => 1, "maximum" => 26}}, ["weeks"])

  def call(%Scope{user: %{id: id}}, %{"weeks" => weeks} = args, _)
      when is_integer(weeks) and weeks in 1..26 and map_size(args) == 1 do
    now = DateTime.utc_now()
    since = DateTime.add(now, -weeks * 7, :day)

    sessions =
      Repo.all(
        from s in WorkoutSession,
          where:
            s.user_id == ^id and s.state == :completed and s.completed_at >= ^since and
              s.completed_at <= ^now,
          order_by: [desc: s.completed_at, desc: s.id],
          limit: 200
      )

    {:ok,
     %{
       "sessions" =>
         sessions |> Enum.filter(&AuthoritativeSession.authoritative?/1) |> Enum.map(&summary/1)
     }}
  end

  def call(_, _, _), do: {:error, "weeks must be an integer from 1 to 26"}

  def summary(s),
    do: %{
      "date" => DateTime.to_iso8601(s.completed_at),
      "type" => Atom.to_string(s.burpee_type),
      "reps" => s.burpee_count_actual,
      "duration_sec" => s.duration_sec_actual,
      "pace_sec" =>
        if(s.burpee_count_actual > 0,
          do: s.duration_sec_actual / s.burpee_count_actual,
          else: nil
        ),
      "feedback" => Map.take(s, [:mood, :primary_limiter, :preference_feedback])
    }
end
