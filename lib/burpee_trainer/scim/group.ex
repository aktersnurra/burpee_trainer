defmodule BurpeeTrainer.Scim.Group do
  @moduledoc "A Pocket ID group as provisioned over SCIM: its Pocket ID id and its members."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "scim_groups" do
    field :external_id, :string
    field :display_name, :string
    field :member_ids, {:array, :integer}, default: []
    field :scim_synced_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
