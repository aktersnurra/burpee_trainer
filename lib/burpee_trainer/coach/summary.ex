defmodule BurpeeTrainer.Coach.Summary do
  @moduledoc "The owner's latest coach summary: one row per user, replaced on every store."
  use Ecto.Schema
  import Ecto.Changeset
  alias BurpeeTrainer.{Repo, Accounts.Scope}

  @type t :: %__MODULE__{}
  schema "coach_summaries" do
    field :user_id, :integer
    field :text, :string
    field :metric_ids, {:array, :string}, default: []
    field :source, Ecto.Enum, values: [:llm, :fallback]
    timestamps(type: :utc_datetime_usec)
  end

  @spec get(Scope.t()) :: t() | nil
  def get(%Scope{user: %{id: id}}), do: Repo.get_by(__MODULE__, user_id: id)

  @spec store(Scope.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def store(%Scope{user: %{id: id}}, attrs) do
    %__MODULE__{user_id: id}
    |> cast(attrs, [:text, :metric_ids, :source])
    |> validate_required([:text, :source])
    |> Repo.insert(
      on_conflict: {:replace, [:text, :metric_ids, :source, :updated_at]},
      conflict_target: :user_id
    )
  end
end
