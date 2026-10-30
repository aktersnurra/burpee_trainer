defmodule BurpeeTrainer.Coach.Exchange do
  @moduledoc "The owner's exchanges with the coach: what they said and what the coach replied."
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Accounts.Scope}

  @type t :: %__MODULE__{}
  schema "coach_exchanges" do
    field :user_id, :integer
    field :message, :string
    field :reply, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The owner's exchanges from `since` on, oldest first; at most the last `limit`."
  @spec since(Scope.t(), DateTime.t(), pos_integer()) :: [t()]
  def since(%Scope{user: %{id: id}}, %DateTime{} = since, limit \\ 20) do
    from(e in __MODULE__,
      where: e.user_id == ^id and e.inserted_at >= ^since,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @spec record(Scope.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record(%Scope{user: %{id: id}}, message, reply) do
    %__MODULE__{user_id: id}
    |> cast(%{message: message, reply: reply}, [:message, :reply])
    |> validate_required([:message, :reply])
    |> Repo.insert()
  end
end
