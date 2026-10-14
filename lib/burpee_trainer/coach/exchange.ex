defmodule BurpeeTrainer.Coach.Exchange do
  @moduledoc "The owner's latest exchange with the coach: one row per user, replaced on each reply."
  use Ecto.Schema
  import Ecto.Changeset
  alias BurpeeTrainer.{Repo, Accounts.Scope}

  @type t :: %__MODULE__{}
  schema "coach_exchanges" do
    field :user_id, :integer
    field :message, :string
    field :reply, :string
    field :suggestions, {:array, :string}, default: []
    timestamps(type: :utc_datetime_usec)
  end

  @spec latest(Scope.t()) :: t() | nil
  def latest(%Scope{user: %{id: id}}), do: Repo.get_by(__MODULE__, user_id: id)

  @spec record(Scope.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record(%Scope{user: %{id: id}}, message, reply, suggestions \\ []) do
    %__MODULE__{user_id: id}
    |> cast(%{message: message, reply: reply, suggestions: suggestions}, [
      :message,
      :reply,
      :suggestions
    ])
    |> validate_required([:message, :reply])
    |> Repo.insert(
      on_conflict: {:replace, [:message, :reply, :suggestions, :updated_at]},
      conflict_target: :user_id
    )
  end
end
