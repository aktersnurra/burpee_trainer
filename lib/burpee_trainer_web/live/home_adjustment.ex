defmodule BurpeeTrainerWeb.HomeAdjustment do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field(:instruction, :string, default: "")
  end

  def changeset(data, attrs), do: cast(data, attrs, [:instruction], empty_values: [])
end
