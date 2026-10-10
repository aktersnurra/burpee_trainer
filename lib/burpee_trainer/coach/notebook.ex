defmodule BurpeeTrainer.Coach.Notebook do
  @moduledoc "Bounded owner memory; owner edits win over stale agent writes."
  use Ecto.Schema
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Accounts.Scope}
  @max 4000
  @type t :: %__MODULE__{}
  schema "coach_notebooks" do
    field :user_id, :integer
    field :body, :string, default: ""
    timestamps(type: :utc_datetime_usec)
  end

  @spec get(Scope.t()) :: %{body: String.t(), updated_at: DateTime.t() | nil}
  def get(%Scope{user: %{id: id}}) do
    case Repo.get_by(__MODULE__, user_id: id) do
      nil -> %{body: "", updated_at: nil}
      nb -> %{body: nb.body, updated_at: nb.updated_at}
    end
  end

  @spec write(Scope.t(), String.t(), DateTime.t() | nil) ::
          {:ok, t()} | {:error, :too_long | :stale_notebook}
  def write(%Scope{user: %{id: id}}, body, seen) when is_binary(body) do
    body = String.trim(body)

    if String.length(body) > @max do
      {:error, :too_long}
    else
      Repo.immediate_transaction(fn ->
        current = Repo.one(from n in __MODULE__, where: n.user_id == ^id)

        cond do
          current == nil and seen == nil ->
            Repo.insert!(%__MODULE__{user_id: id, body: body})

          current != nil and current.updated_at == seen ->
            now = DateTime.utc_now()

            now =
              if DateTime.compare(now, current.updated_at) == :gt,
                do: now,
                else: DateTime.add(current.updated_at, 1, :microsecond)

            current |> Ecto.Changeset.change(body: body, updated_at: now) |> Repo.update!()

          true ->
            Repo.rollback(:stale_notebook)
        end
      end)
    end
  end
end
