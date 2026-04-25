defmodule BurpeeTrainer.Workouts.StylePerformance do
  use Ecto.Schema

  alias BurpeeTrainer.Accounts.User

  @burpee_types [:six_count, :navy_seal]
  @time_buckets [:morning, :afternoon, :evening, :night]

  @type t :: %__MODULE__{}

  schema "style_performances" do
    field :style_name, :string
    field :burpee_type, Ecto.Enum, values: @burpee_types
    field :mood, :integer
    field :level, :string
    field :time_of_day_bucket, :string
    field :session_count, :integer, default: 0
    field :completion_ratio_sum, :float, default: 0.0
    field :rate_sum, :float, default: 0.0

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def burpee_types, do: @burpee_types
  def time_buckets, do: @time_buckets
end
