defmodule BurpeeTrainer.Workouts.WorkoutPlan do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.Block

  @burpee_types [:six_count, :navy_seal]

  @type t :: %__MODULE__{}

  schema "workout_plans" do
    field :name, :string
    field :burpee_type, Ecto.Enum, values: @burpee_types
    field :warmup_enabled, :boolean, default: false
    field :warmup_reps, :integer
    field :warmup_rounds, :integer
    field :rest_sec_warmup_between, :integer, default: 120
    field :rest_sec_warmup_before_main, :integer, default: 180
    field :shave_off_sec, :integer
    field :shave_off_block_count, :integer

    belongs_to :user, User

    has_many :blocks, Block,
      foreign_key: :plan_id,
      preload_order: [asc: :position],
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def burpee_types, do: @burpee_types

  @doc """
  Plan changeset. `user_id` is set programmatically by the context, not
  cast from attrs.
  """
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :name,
      :burpee_type,
      :warmup_enabled,
      :warmup_reps,
      :warmup_rounds,
      :rest_sec_warmup_between,
      :rest_sec_warmup_before_main,
      :shave_off_sec,
      :shave_off_block_count
    ])
    |> validate_required([:name, :burpee_type])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_number(:warmup_reps, greater_than: 0)
    |> validate_number(:warmup_rounds, greater_than: 0)
    |> validate_number(:rest_sec_warmup_between, greater_than_or_equal_to: 0)
    |> validate_number(:rest_sec_warmup_before_main, greater_than_or_equal_to: 0)
    |> validate_number(:shave_off_sec, greater_than_or_equal_to: 0)
    |> validate_number(:shave_off_block_count, greater_than_or_equal_to: 0)
    |> validate_warmup_requirements()
    |> cast_assoc(:blocks,
      with: &Block.changeset/2,
      sort_param: :blocks_sort,
      drop_param: :blocks_drop,
      required: true
    )
    |> validate_shave_off_feasibility()
  end

  defp validate_warmup_requirements(changeset) do
    case get_field(changeset, :warmup_enabled) do
      true ->
        changeset
        |> validate_required([:warmup_reps, :warmup_rounds])

      _ ->
        changeset
    end
  end

  # Shave-off subtracts `shave_off_sec` from the last set's
  # `end_of_set_rest` on each of the first N blocks (N =
  # `shave_off_block_count`). If the last set's trailing rest is
  # smaller than the shave amount, the user has nothing to cut — the
  # plan can't absorb the shave without speeding up pacing.
  defp validate_shave_off_feasibility(changeset) do
    shave_sec = get_field(changeset, :shave_off_sec) || 0
    shave_n = get_field(changeset, :shave_off_block_count) || 0

    cond do
      shave_sec <= 0 ->
        changeset

      shave_n <= 0 ->
        changeset

      true ->
        sorted_blocks = sorted_blocks_from_changeset(changeset)
        affected = Enum.take(sorted_blocks, shave_n)
        validate_shave_affected_blocks(changeset, affected, shave_sec)
    end
  end

  defp validate_shave_affected_blocks(changeset, blocks, shave_sec) do
    offenders =
      Enum.filter(blocks, fn block ->
        last_rest = last_set_end_of_set_rest(block)
        last_rest < shave_sec
      end)

    if offenders == [] do
      changeset
    else
      positions = Enum.map_join(offenders, ", ", &"block #{block_position(&1)}")

      add_error(
        changeset,
        :shave_off_sec,
        "not enough rest to shave #{shave_sec}s on #{positions} — reduce shave or increase pacing (sec/rep) to free up end-of-set rest"
      )
    end
  end

  defp sorted_blocks_from_changeset(changeset) do
    case Map.get(changeset.changes, :blocks) do
      blocks when is_list(blocks) ->
        Enum.sort_by(blocks, &get_field(&1, :position, 0))

      _ ->
        []
    end
  end

  defp last_set_end_of_set_rest(block_changeset) do
    case Map.get(block_changeset.changes, :sets) do
      sets when is_list(sets) and sets != [] ->
        sets
        |> Enum.sort_by(&get_field(&1, :position, 0))
        |> List.last()
        |> get_field(:end_of_set_rest, 0)

      _ ->
        0
    end
  end

  defp block_position(block_changeset), do: get_field(block_changeset, :position, 0)
end
