defmodule BurpeeTrainer.Workouts.WorkoutVideo do
  use Ecto.Schema
  import Ecto.Changeset

  @formats [:follow_along]

  @type format :: :follow_along

  @type t :: %__MODULE__{}

  schema "workout_videos" do
    field :name, :string
    field :filename, :string
    field :burpee_type, Ecto.Enum, values: [:six_count, :navy_seal]
    field :duration_sec, :integer
    field :burpee_count, :integer
    field :available, :boolean, default: true
    field :format, Ecto.Enum, values: @formats, default: :follow_along

    timestamps(updated_at: false)
  end

  @spec formats() :: [format()]
  def formats, do: @formats

  def changeset(video, attrs) do
    video
    |> cast(attrs, [
      :name,
      :filename,
      :burpee_type,
      :duration_sec,
      :burpee_count,
      :available,
      :format
    ])
    |> validate_required([:name, :filename, :burpee_type, :duration_sec])
    |> validate_number(:duration_sec, greater_than: 0)
    |> unique_constraint(:filename)
    |> check_constraint(:format, name: :workout_videos_format_check)
  end
end
