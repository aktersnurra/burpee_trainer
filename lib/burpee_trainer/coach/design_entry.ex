defmodule BurpeeTrainer.Coach.DesignEntry do
  use Ecto.Schema
  @type t :: %__MODULE__{}
  schema "workout_design_entries" do
    field(:design_session_id, :integer)
    field(:attempt_id, Ecto.UUID)

    field(:kind, Ecto.Enum,
      values: [:initial_context, :baseline, :instruction, :proposal, :outcome]
    )

    field(:payload, :map)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
