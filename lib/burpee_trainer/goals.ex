defmodule BurpeeTrainer.Goals do
  @moduledoc """
  Context for goals. At most one `:active` goal per `(user_id, burpee_type)`
  is enforced by a partial unique index. Creating a new goal for a type
  automatically abandons any existing active goal for that type.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.{Scope, User}
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Repo

  @doc """
  Fetch the (single) active goal for a `(scope, burpee_type)` pair, or
  nil if none exists.
  """
  @spec get_active_goal(Scope.t(), atom) :: Goal.t() | nil
  def get_active_goal(%Scope{user: %User{id: user_id}}, burpee_type) when is_atom(burpee_type) do
    Repo.one(
      from goal in Goal,
        where:
          goal.user_id == ^user_id and
            goal.burpee_type == ^burpee_type and
            goal.status == :active
    )
  end

  @doc """
  Transition a goal to `:achieved`.
  """
  @spec mark_achieved(Goal.t()) :: {:ok, Goal.t()} | {:error, Ecto.Changeset.t()}
  def mark_achieved(%Goal{} = goal) do
    goal |> Goal.status_changeset(:achieved) |> Repo.update()
  end

  @doc "Best scoped completed non-warmup session since a bound, optionally within the goal duration."
  def best_session(%Scope{user: %{id: id}}, type, since, max_duration \\ 86400) do
    now = DateTime.utc_now()

    Repo.one(
      from s in BurpeeTrainer.Workouts.WorkoutSession,
        where:
          s.user_id == ^id and s.state == :completed and s.burpee_type == ^type and
            s.completed_at >= ^since and s.completed_at <= ^now and s.burpee_count_actual > 0 and
            s.duration_sec_actual > 0 and s.duration_sec_actual <= ^max_duration and
            (is_nil(s.tags) or s.tags != "warmup"),
        order_by: [desc: s.burpee_count_actual, asc: s.duration_sec_actual, desc: s.id],
        limit: 1
    )
  end

  def progress(%Scope{} = scope, %Goal{user_id: user_id} = goal) when user_id == scope.user.id do
    since = DateTime.new!(goal.date_baseline, ~T[00:00:00], "Etc/UTC")
    best = best_session(scope, goal.burpee_type, since, goal.duration_sec_target)
    current = max(goal.burpee_count_baseline, if(best, do: best.burpee_count_actual, else: 0))

    fraction =
      (current - goal.burpee_count_baseline) /
        max(goal.burpee_count_target - goal.burpee_count_baseline, 1)

    %{
      "current_reps" => current,
      "current_duration_sec" =>
        if(best, do: best.duration_sec_actual, else: goal.duration_sec_baseline),
      "fraction" => min(max(fraction, 0.0), 1.0)
    }
  end

  def list(%Scope{user: %{id: id}}),
    do:
      Repo.all(
        from g in Goal,
          where: g.user_id == ^id and g.status in [:active, :proposed],
          order_by: [asc: g.id]
      )

  def confirm(%Scope{} = scope, id), do: transition_proposal(scope, id, :active)
  def dismiss(%Scope{} = scope, id), do: transition_proposal(scope, id, :abandoned)

  defp transition_proposal(%Scope{user: %{id: user_id}}, id, status) do
    Repo.immediate_transaction(fn ->
      case Repo.get_by(Goal, user_id: user_id, id: id, status: :proposed) do
        nil ->
          Repo.rollback(:not_found)

        goal ->
          if status == :active do
            Repo.update_all(
              from(g in Goal,
                where:
                  g.user_id == ^user_id and g.burpee_type == ^goal.burpee_type and
                    g.status == :active
              ),
              set: [status: :abandoned]
            )
          end

          case goal |> Goal.status_changeset(status) |> Repo.update() do
            {:ok, goal} -> goal
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end
end
