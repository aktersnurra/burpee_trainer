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
  All goals for a user (active, achieved, abandoned), newest first.
  """
  @spec list_goals(User.t()) :: [Goal.t()]
  def list_goals(%User{id: user_id}) do
    Repo.all(
      from goal in Goal,
        where: goal.user_id == ^user_id,
        order_by: [desc: goal.inserted_at]
    )
  end

  @doc """
  Active goals for a user, one per `burpee_type` at most.
  """
  @spec list_active_goals(User.t()) :: [Goal.t()]
  def list_active_goals(%User{id: user_id}) do
    Repo.all(
      from goal in Goal,
        where: goal.user_id == ^user_id and goal.status == :active
    )
  end

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
  Fetch a goal by id scoped to a user. Raises if not found.
  """
  @spec get_goal!(User.t(), integer) :: Goal.t()
  def get_goal!(%User{id: user_id}, id) do
    Repo.one!(
      from goal in Goal,
        where: goal.id == ^id and goal.user_id == ^user_id
    )
  end

  @doc """
  Create a goal for a user. Any existing `:active` goal for the same
  `burpee_type` is abandoned atomically.
  """
  @spec create_goal(User.t(), map) :: {:ok, Goal.t()} | {:error, Ecto.Changeset.t()}
  def create_goal(%User{id: user_id} = user, attrs) do
    Repo.transaction(fn ->
      burpee_type = attrs["burpee_type"] || attrs[:burpee_type]

      if burpee_type do
        case get_active_goal(user, normalize_burpee_type(burpee_type)) do
          nil -> :noop
          existing -> existing |> Goal.status_changeset(:abandoned) |> Repo.update!()
        end
      end

      result =
        %Goal{user_id: user_id}
        |> Goal.changeset(attrs)
        |> Repo.insert()

      case result do
        {:ok, goal} -> goal
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Transition a goal to `:abandoned`.
  """
  @spec abandon_goal(Goal.t()) :: {:ok, Goal.t()} | {:error, Ecto.Changeset.t()}
  def abandon_goal(%Goal{} = goal) do
    goal |> Goal.status_changeset(:abandoned) |> Repo.update()
  end

  @doc """
  Transition a goal to `:achieved`.
  """
  @spec mark_achieved(Goal.t()) :: {:ok, Goal.t()} | {:error, Ecto.Changeset.t()}
  def mark_achieved(%Goal{} = goal) do
    goal |> Goal.status_changeset(:achieved) |> Repo.update()
  end

  @doc """
  Blank changeset for a new goal, useful for forms.
  """
  @spec change_goal(Goal.t(), map) :: Ecto.Changeset.t()
  def change_goal(%Goal{} = goal, attrs \\ %{}), do: Goal.changeset(goal, attrs)

  defp normalize_burpee_type(value) when is_atom(value), do: value
  defp normalize_burpee_type("six_count"), do: :six_count
  defp normalize_burpee_type("navy_seal"), do: :navy_seal
  defp normalize_burpee_type(_), do: nil
end
