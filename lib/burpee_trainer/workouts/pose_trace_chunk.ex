defmodule BurpeeTrainer.Workouts.PoseTraceChunk do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Workouts.PoseCaptureRun

  @segments [:warmup, :main]
  @max_payload_json_bytes 250_000
  @max_sample_count 600

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
    |> validate_number(:sample_count, greater_than: 0, less_than_or_equal_to: @max_sample_count)
    |> validate_ended_after_started()
    |> validate_payload_json()
    |> unique_constraint(:chunk_index,
      name: :pose_trace_chunks_pose_capture_run_id_chunk_index_index
    )
  end

  defp validate_payload_json(changeset) do
    payload_json = get_field(changeset, :payload_json)

    cond do
      not is_binary(payload_json) ->
        changeset

      byte_size(payload_json) > @max_payload_json_bytes ->
        add_error(changeset, :payload_json, "is too large")

      true ->
        validate_payload_samples(changeset, payload_json)
    end
  end

  defp validate_payload_samples(changeset, payload_json) do
    case Jason.decode(payload_json) do
      {:ok, %{"samples" => samples}} when is_list(samples) ->
        sample_count = get_field(changeset, :sample_count)

        if is_integer(sample_count) and length(samples) != sample_count do
          add_error(changeset, :payload_json, "sample count must match samples length")
        else
          changeset
        end

      {:ok, _payload} ->
        add_error(changeset, :payload_json, "must contain samples")

      {:error, _reason} ->
        add_error(changeset, :payload_json, "must be valid JSON")
    end
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
