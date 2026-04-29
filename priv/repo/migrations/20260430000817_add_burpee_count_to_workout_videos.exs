defmodule BurpeeTrainer.Repo.Migrations.AddBurpeeCountToWorkoutVideos do
  use Ecto.Migration

  def up do
    alter table(:workout_videos) do
      add :burpee_count, :integer
    end

    flush()

    repo().query!("SELECT id, filename FROM workout_videos")
    |> Map.get(:rows)
    |> Enum.each(fn [id, filename] ->
      case Regex.run(~r/(?:6c|ns)_(\d+)/, filename, capture: :all_but_first) do
        [n] ->
          repo().query!(
            "UPDATE workout_videos SET burpee_count = ? WHERE id = ?",
            [String.to_integer(n), id]
          )

        _ ->
          :ok
      end
    end)
  end

  def down do
    alter table(:workout_videos) do
      remove :burpee_count
    end
  end
end
