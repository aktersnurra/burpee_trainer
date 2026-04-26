defmodule Mix.Tasks.BurpeeTrainer.AddVideo do
  @shortdoc "Add a workout video record: mix burpee_trainer.add_video NAME FILENAME BURPEE_TYPE DURATION_SEC"

  use Mix.Task

  @impl Mix.Task
  def run([name, filename, burpee_type_str, duration_sec_str]) do
    Mix.Task.run("app.start")

    burpee_type =
      case burpee_type_str do
        t when t in ["six_count", "navy_seal"] -> t
        _ -> Mix.raise("BURPEE_TYPE must be six_count or navy_seal, got: #{burpee_type_str}")
      end

    duration_sec =
      case Integer.parse(duration_sec_str) do
        {n, ""} when n > 0 -> n
        _ -> Mix.raise("DURATION_SEC must be a positive integer, got: #{duration_sec_str}")
      end

    case BurpeeTrainer.Videos.create_video(%{
           name: name,
           filename: filename,
           burpee_type: burpee_type,
           duration_sec: duration_sec
         }) do
      {:ok, video} ->
        Mix.shell().info("Added video ##{video.id}: #{video.name} (#{video.filename})")

      {:error, changeset} ->
        Mix.raise("Failed to add video: #{inspect(changeset.errors)}")
    end
  end

  def run(_) do
    Mix.raise("Usage: mix burpee_trainer.add_video NAME FILENAME BURPEE_TYPE DURATION_SEC")
  end
end
