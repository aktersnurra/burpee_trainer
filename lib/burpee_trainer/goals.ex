defmodule BurpeeTrainer.Goals do
  @moduledoc """
  Context for goals. At most one `:active` goal per `(user_id, burpee_type)`
  is enforced by a partial unique index. Creating a new goal for a type
  automatically abandons any existing active goal for that type.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Repo

  @doc """
  Fetch the (single) active goal for a `(user, burpee_type)` pair, or
  nil if none exists.
  """
  @spec get_active_goal(User.t(), atom) :: Goal.t() | nil
  def get_active_goal(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
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
end
