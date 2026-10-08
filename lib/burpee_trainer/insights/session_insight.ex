defmodule BurpeeTrainer.Insights.SessionInsight do
  @moduledoc "A single immutable narration of an owned completed session."
  use Ecto.Schema
  import Ecto.Changeset

  schema "session_insights" do
    field :session_id, :integer
    field :user_id, :integer
    field :headline, :string
    field :points, :map
    field :source, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(insight, attrs) do
    insight
    |> cast(attrs, [:headline, :points, :source])
    |> validate_required([:session_id, :user_id, :headline, :points, :source])
    |> validate_length(:headline, max: 80)
    |> validate_inclusion(:source, ["llm", "fallback"])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:session_id)
  end
end
