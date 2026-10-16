defmodule BurpeeTrainer.Videos do
  @moduledoc """
  Context for workout videos. Videos are global (no user_id) — they are
  admin-seeded content, not per-user records.
  """

  import Ecto.Query

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.WorkoutVideo

  def list_home_videos do
    Repo.all(
      from(v in WorkoutVideo,
        where: v.available == true and v.format == :follow_along,
        order_by: [asc: v.name, asc: v.id]
      )
    )
  end

  @spec create_video(map) :: {:ok, WorkoutVideo.t()} | {:error, Ecto.Changeset.t()}
  def create_video(attrs) do
    %WorkoutVideo{}
    |> WorkoutVideo.changeset(attrs)
    |> Repo.insert()
  end
end
