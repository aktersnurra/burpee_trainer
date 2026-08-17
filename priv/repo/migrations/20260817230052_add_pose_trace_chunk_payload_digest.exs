defmodule BurpeeTrainer.Repo.Migrations.AddPoseTraceChunkPayloadDigest do
  use Ecto.Migration
  import Ecto.Query

  def up do
    alter table(:pose_trace_chunks) do
      add :payload_digest, :string, null: false, default: ""
    end

    flush()

    for {id, payload_json} <-
          repo().all(from(chunk in "pose_trace_chunks", select: {chunk.id, chunk.payload_json})) do
      repo().update_all(
        from(chunk in "pose_trace_chunks", where: chunk.id == ^id),
        set: [payload_digest: payload_digest(payload_json)]
      )
    end
  end

  def down do
    alter table(:pose_trace_chunks) do
      remove :payload_digest
    end
  end

  defp payload_digest(payload_json) do
    :crypto.hash(:sha256, payload_json)
    |> Base.encode16(case: :lower)
  end
end
