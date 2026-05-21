defmodule BurpeeTrainer.Coach.Arm do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User

  @burpee_types ["six_count", "navy_seal"]
  @dimensions ["reps", "pace", "rest", "baseline"]

  schema "coach_arms" do
    field :burpee_type, :string
    field :dimension, :string
    field :step, :float
    field :alpha, :float, default: 1.0
    field :beta, :float, default: 1.0

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(arm, attrs) do
    arm
    |> cast(attrs, [:user_id, :burpee_type, :dimension, :step, :alpha, :beta])
    |> validate_required([:user_id, :burpee_type, :dimension, :step])
    |> validate_inclusion(:burpee_type, @burpee_types)
    |> validate_inclusion(:dimension, @dimensions)
    |> validate_number(:alpha, greater_than: 0)
    |> validate_number(:beta, greater_than: 0)
    |> unique_constraint([:user_id, :burpee_type, :dimension, :step])
  end
end
