defmodule BurpeeTrainer.Goals.Goal do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User

  @burpee_types [:six_count, :navy_seal]
  @statuses [:active, :achieved, :abandoned]

  @type t :: %__MODULE__{}

  schema "goals" do
    field :burpee_type, Ecto.Enum, values: @burpee_types
    field :burpee_count_target, :integer
    field :duration_sec_target, :integer
    field :date_target, :date
    field :burpee_count_baseline, :integer
    field :duration_sec_baseline, :integer
    field :date_baseline, :date
    field :status, Ecto.Enum, values: @statuses, default: :active

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def burpee_types, do: @burpee_types
  def statuses, do: @statuses

  @doc """
  Create changeset. `user_id` is set by the context.
  """
  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [
      :burpee_type,
      :burpee_count_target,
      :duration_sec_target,
      :date_target,
      :burpee_count_baseline,
      :duration_sec_baseline,
      :date_baseline,
      :status
    ])
    |> validate_required([
      :burpee_type,
      :burpee_count_target,
      :duration_sec_target,
      :date_target,
      :burpee_count_baseline,
      :duration_sec_baseline,
      :date_baseline
    ])
    |> validate_number(:burpee_count_target, greater_than: 0)
    |> validate_number(:duration_sec_target, greater_than: 0)
    |> validate_number(:burpee_count_baseline, greater_than_or_equal_to: 0)
    |> validate_number(:duration_sec_baseline, greater_than_or_equal_to: 0)
    |> validate_date_target_after_baseline()
    |> unique_constraint([:user_id, :burpee_type],
      name: :goals_active_user_type_index,
      message: "an active goal already exists for this burpee type"
    )
  end

  @doc """
  Status-transition changeset (e.g. :active → :abandoned | :achieved).
  """
  def status_changeset(goal, status) when status in @statuses do
    change(goal, status: status)
  end

  defp validate_date_target_after_baseline(changeset) do
    baseline = get_field(changeset, :date_baseline)
    target = get_field(changeset, :date_target)

    if baseline && target && Date.compare(target, baseline) != :gt do
      add_error(changeset, :date_target, "must be after date_baseline")
    else
      changeset
    end
  end
end
