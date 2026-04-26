defmodule BurpeeTrainer.Videos do
  @moduledoc """
  Context for workout videos. Videos are global (no user_id) — they are
  admin-seeded content, not per-user records.
  """

  import Ecto.Query

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.WorkoutVideo

  @spec list_videos() :: [WorkoutVideo.t()]
  def list_videos do
    Repo.all(from v in WorkoutVideo, order_by: [asc: v.inserted_at])
  end

  @spec list_videos(atom) :: [WorkoutVideo.t()]
  def list_videos(burpee_type) when is_atom(burpee_type) do
    Repo.all(
      from v in WorkoutVideo,
        where: v.burpee_type == ^burpee_type,
        order_by: [asc: v.inserted_at]
    )
  end

  @spec get_video!(integer) :: WorkoutVideo.t()
  def get_video!(id), do: Repo.get!(WorkoutVideo, id)

  @spec create_video(map) :: {:ok, WorkoutVideo.t()} | {:error, Ecto.Changeset.t()}
  def create_video(attrs) do
    %WorkoutVideo{}
    |> WorkoutVideo.changeset(attrs)
    |> Repo.insert()
  end
end
