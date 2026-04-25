defmodule BurpeeTrainer.Workouts.Set do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Workouts.Block

  @type t :: %__MODULE__{}

  # Terminology:
  #
  #   sec_per_rep     cadence — total seconds between rep starts
  #                   (movement + inter-rep pause)
  #   sec_per_burpee  actual movement time of one burpee
  #                   (must be ≤ sec_per_rep)
  #   end_of_set_rest trailing rest after the final rep of the set
  #
  # Total set time = burpee_count * sec_per_rep + end_of_set_rest
  schema "sets" do
    field :position, :integer
    field :burpee_count, :integer
    field :sec_per_rep, :float
    field :sec_per_burpee, :float
    field :end_of_set_rest, :integer, default: 0

    # UX-layer input: total set duration in whole minutes. When present,
    # overrides `end_of_set_rest` via `apply_duration_min/1`.
    field :duration_min, :integer, virtual: true

    belongs_to :block, Block

    timestamps(type: :utc_datetime)
  end

  def changeset(set, attrs) do
    set
    |> cast(attrs, [
      :position,
      :burpee_count,
      :sec_per_rep,
      :sec_per_burpee,
      :end_of_set_rest,
      :duration_min
    ])
    |> validate_required([:position, :burpee_count, :sec_per_rep, :sec_per_burpee])
    |> validate_number(:position, greater_than: 0)
    |> validate_number(:burpee_count, greater_than_or_equal_to: 0)
    |> validate_number(:sec_per_rep, greater_than: 0)
    |> validate_number(:sec_per_burpee, greater_than: 0)
    |> validate_burpee_within_rep()
    |> apply_duration_min()
    |> validate_number(:end_of_set_rest, greater_than_or_equal_to: 0)
  end

  defp validate_burpee_within_rep(changeset) do
    rep = get_field(changeset, :sec_per_rep)
    burpee = get_field(changeset, :sec_per_burpee)

    if is_number(rep) and is_number(burpee) and burpee > rep do
      add_error(
        changeset,
        :sec_per_burpee,
        "must be ≤ sec/rep (burpee movement can't be longer than the full rep cycle)"
      )
    else
      changeset
    end
  end

  defp apply_duration_min(changeset) do
    duration_min = get_change(changeset, :duration_min)
    burpees = get_field(changeset, :burpee_count)
    sec_per_rep = get_field(changeset, :sec_per_rep)

    cond do
      is_nil(duration_min) ->
        changeset

      not is_number(burpees) or not is_number(sec_per_rep) ->
        changeset

      duration_min < 0 ->
        add_error(changeset, :duration_min, "must be at least 0")

      true ->
        work_sec = burpees * sec_per_rep
        target_sec = duration_min * 60
        rest_sec = round(target_sec - work_sec)

        if rest_sec < 0 do
          min_min = ceil(work_sec / 60)

          add_error(
            changeset,
            :duration_min,
            "too short — #{burpees} burpees at #{format_cadence(sec_per_rep)} need ≥ #{min_min} min, or pick faster pacing"
          )
        else
          put_change(changeset, :end_of_set_rest, rest_sec)
        end
    end
  end

  defp format_cadence(p) when is_float(p), do: :erlang.float_to_binary(p, decimals: 1) <> " s/rep"
  defp format_cadence(p), do: "#{p} s/rep"
end
