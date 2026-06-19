defmodule BurpeeTrainer.Workouts.PoseTraceChunk do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Workouts.PoseCaptureRun

  @segments [:warmup, :main]

  @type t :: %__MODULE__{}

  schema "pose_trace_chunks" do
    field(:segment, Ecto.Enum, values: @segments)
    field(:chunk_index, :integer)
    field(:started_at_ms, :integer)
    field(:ended_at_ms, :integer)
    field(:sample_count, :integer)
    field(:payload_json, :string)

    belongs_to(:pose_capture_run, PoseCaptureRun)

    timestamps(type: :utc_datetime)
  end

  @spec segments() :: [:warmup | :main]
  def segments, do: @segments

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :segment,
      :chunk_index,
      :started_at_ms,
      :ended_at_ms,
      :sample_count,
      :payload_json
    ])
    |> validate_required([
      :pose_capture_run_id,
      :segment,
      :chunk_index,
      :started_at_ms,
      :ended_at_ms,
      :sample_count,
      :payload_json
    ])
    |> validate_number(:chunk_index, greater_than_or_equal_to: 0)
    |> validate_number(:started_at_ms, greater_than_or_equal_to: 0)
    |> validate_number(:ended_at_ms, greater_than_or_equal_to: 0)
    |> validate_number(:sample_count, greater_than: 0)
    |> validate_ended_after_started()
    |> unique_constraint(:chunk_index, name: :pose_trace_chunks_pose_capture_run_id_chunk_index_index)
  end

  defp validate_ended_after_started(changeset) do
    started_at_ms = get_field(changeset, :started_at_ms)
    ended_at_ms = get_field(changeset, :ended_at_ms)

    if is_integer(started_at_ms) and is_integer(ended_at_ms) and ended_at_ms < started_at_ms do
      add_error(changeset, :ended_at_ms, "must be greater than or equal to started_at_ms")
    else
      changeset
    end
  end
end
