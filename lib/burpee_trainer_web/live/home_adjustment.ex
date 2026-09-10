defmodule BurpeeTrainerWeb.HomeAdjustment do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field :instruction, :string, default: ""
  end

  def changeset(data, attrs), do: cast(data, attrs, [:instruction], empty_values: [])

  def operation(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:ok, {:start, ""}}
      String.length(text) <= 500 and byte_size(text) <= 4_000 -> {:ok, {:update, text}}
      true -> {:error, :invalid_instruction}
    end
  end

  def operation(_), do: {:error, :invalid_instruction}
end
