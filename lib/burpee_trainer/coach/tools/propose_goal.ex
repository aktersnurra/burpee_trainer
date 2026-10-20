defmodule BurpeeTrainer.Coach.Tools.ProposeGoal do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.{Repo, Accounts.Scope, Goals}
  def name, do: "propose_goal"

  def description,
    do: "Propose a goal only when explicitly requested; owner confirmation required."

  def schema,
    do:
      Tool.object(
        %{
          "burpee_type" => %{"type" => "string", "enum" => ["six_count", "navy_seal"]},
          "burpee_count_target" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "reps in one 20-minute session"
          },
          "date_target" => %{"type" => "string"}
        },
        ["burpee_type", "burpee_count_target", "date_target"]
      )

  def call(
        %Scope{user: %{id: id}} = scope,
        %{
          "burpee_type" => type,
          "burpee_count_target" => reps,
          "date_target" => date
        } = args,
        _
      )
      when type in ["six_count", "navy_seal"] and is_integer(reps) and reps > 0 and
             is_binary(date) and map_size(args) == 3 do
    type_atom = if type == "six_count", do: :six_count, else: :navy_seal
    since = DateTime.add(DateTime.utc_now(), -42, :day)

    best = Goals.best_session(scope, type_atom, since)

    attrs =
      Map.merge(args, %{
        "status" => "proposed",
        "date_baseline" => Date.to_iso8601(Date.utc_today()),
        "burpee_count_baseline" => if(best, do: best.burpee_count_actual, else: 0),
        "duration_sec_baseline" => if(best, do: best.duration_sec_actual, else: 0)
      })

    case %Goal{user_id: id} |> Goal.changeset(attrs) |> Repo.insert() do
      {:ok, goal} ->
        {:ok, %{"goal_id" => goal.id, "status" => "proposed"}}

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
        {:error, "invalid goal: " <> Jason.encode!(errors)}
    end
  end

  def call(_, _, _), do: {:error, "invalid goal arguments"}
end
