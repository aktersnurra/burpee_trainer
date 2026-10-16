defmodule BurpeeTrainer.Coach.LlmCall do
  use Ecto.Schema
  @type t :: %__MODULE__{}

  schema "llm_calls" do
    field :user_id, :integer
    field :purpose, :string
    field :run_id, :string
    field :model, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :cost_usd, :float
    field :reserved_cost_usd, :float, default: 0.0
    field :outcome, :string
    field :duration_ms, :integer, default: 0
    field :inserted_at, :utc_datetime_usec
  end
end
