defmodule BurpeeTrainer.Repo.Migrations.CompressPoseTraces do
  @moduledoc """
  Pose-trace chunks are stored gzipped (`Workouts.GzipText`): a 20-minute camera session
  took about 120 MB as plain JSON. Existing chunks are compressed one at a time; the file
  only shrinks after a `VACUUM`.
  """
  use Ecto.Migration

  def up, do: convert("blob", &{:blob, :zlib.gzip(&1)})
  def down, do: convert("text", &:zlib.gunzip/1)

  # Converts every chunk not yet stored as `type`.
  defp convert(type, fun) do
    ids =
      repo().query!("SELECT id FROM pose_trace_chunks WHERE typeof(payload_json) <> ?1", [type]).rows

    for [id] <- ids do
      [[payload]] =
        repo().query!("SELECT payload_json FROM pose_trace_chunks WHERE id = ?1", [id]).rows

      repo().query!("UPDATE pose_trace_chunks SET payload_json = ?1 WHERE id = ?2", [
        fun.(payload),
        id
      ])
    end
  end
end
