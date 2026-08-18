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

  @coach_evidence_video_limit 24

  @spec list_available_follow_along_videos() :: [WorkoutVideo.t()]
  def list_available_follow_along_videos do
    Repo.all(
      from v in WorkoutVideo,
        where: v.available == true and v.format == :follow_along,
        order_by: [asc: v.name, asc: v.id],
        limit: ^@coach_evidence_video_limit
    )
  end

  @spec list_available_follow_along_videos(atom) :: [WorkoutVideo.t()]
  def list_available_follow_along_videos(burpee_type) when is_atom(burpee_type) do
    Repo.all(
      from v in WorkoutVideo,
        where:
          v.available == true and v.format == :follow_along and v.burpee_type == ^burpee_type,
        order_by: [asc: v.name, asc: v.id],
        limit: ^@coach_evidence_video_limit
    )
  end

  @spec get_video!(integer) :: WorkoutVideo.t()
  def get_video!(id), do: Repo.get!(WorkoutVideo, id)

  @spec get_available_video(pos_integer()) :: {:ok, WorkoutVideo.t()} | {:error, :not_found}
  def get_available_video(id) when is_integer(id) and id > 0 do
    case Repo.get_by(WorkoutVideo, id: id, available: true, format: :follow_along) do
      %WorkoutVideo{} = video -> {:ok, video}
      nil -> {:error, :not_found}
    end
  end

  def get_available_video(_id), do: {:error, :not_found}

  @spec create_video(map) :: {:ok, WorkoutVideo.t()} | {:error, Ecto.Changeset.t()}
  def create_video(attrs) do
    %WorkoutVideo{}
    |> WorkoutVideo.changeset(attrs)
    |> Repo.insert()
  end
end
