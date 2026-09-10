defmodule BurpeeTrainer.Coach.Setting do
  use Ecto.Schema

  schema "coach_settings" do
    field(:user_id, :integer)
    field(:settings, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end
end
