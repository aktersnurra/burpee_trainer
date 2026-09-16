defmodule BurpeeTrainer.Coach.GuidanceEntry do
  @moduledoc "A user-authored coach instruction and its optional curated reading."

  use Ecto.Schema

  schema "coach_guidance_entries" do
    field :user_id, :integer
    field :text, :string
    field :kind, :string, default: "pending"
    field :summary, :string

    timestamps(type: :utc_datetime_usec)
  end
end
