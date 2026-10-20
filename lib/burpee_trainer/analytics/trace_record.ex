defmodule BurpeeTrainer.Analytics.TraceRecord do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "analytics_traces" do
    field :user_id, :integer
    field :payload, :string
    field :expires_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
