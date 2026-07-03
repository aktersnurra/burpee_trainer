defmodule BurpeeTrainer.Workouts.ExecutionProgram do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "execution_programs" do
    field(:content_hash, :string)
    field(:schema_version, :integer)
    field(:solver_version, :integer)
    field(:burpee_type, Ecto.Enum, values: [:six_count, :navy_seal])
    field(:target_reps, :integer)
    field(:target_duration_sec, :integer)
    field(:event_count, :integer)
    field(:program_json, :map)
    field(:summary_json, :map)

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(program, attrs) do
    program
    |> cast(attrs, [
      :content_hash,
      :schema_version,
      :solver_version,
      :burpee_type,
      :target_reps,
      :target_duration_sec,
      :event_count,
      :program_json,
      :summary_json
    ])
    |> validate_required([
      :content_hash,
      :schema_version,
      :solver_version,
      :burpee_type,
      :target_reps,
      :target_duration_sec,
      :event_count,
      :program_json,
      :summary_json
    ])
    |> validate_number(:schema_version, greater_than: 0)
    |> validate_number(:solver_version, greater_than: 0)
    |> validate_number(:target_reps, greater_than: 0)
    |> validate_number(:target_duration_sec, greater_than: 0)
    |> validate_number(:event_count, greater_than: 0)
    |> unique_constraint(:content_hash)
  end
end
