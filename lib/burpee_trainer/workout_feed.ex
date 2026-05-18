defmodule BurpeeTrainer.WorkoutFeed do
  @moduledoc """
  Aggregates workout plans (user-scoped) and videos (global) into a unified
  list of `WorkoutItem`s for the Workouts screen. Supports filtering by
  source, burpee_type, and level.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Levels
  alias BurpeeTrainer.Planner
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Videos
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainer.WorkoutFeed.WorkoutItem

  @type filter :: %{
          optional(:source) => :mine | :videos | :all,
          optional(:burpee_type) => :six_count | :navy_seal,
          optional(:level) => atom()
        }

  @doc """
  Returns a list of `WorkoutItem`s for `user`, optionally filtered.

  Sort order:
  - Plans before videos (when source is :all / unspecified)
  - Plans: most-recently-used first (nil last), then burpee_count asc, then inserted_at desc
  - Videos: inserted_at asc
  """
  @spec list(User.t(), filter()) :: [WorkoutItem.t()]
  def list(user, filters \\ %{}) do
    source = Map.get(filters, :source, :all)

    plans =
      if source in [:all, :mine] do
        user
        |> Workouts.list_plans()
        |> Enum.map(&plan_to_item(user, &1))
      else
        []
      end

    videos =
      if source in [:all, :videos] do
        Videos.list_videos()
        |> Enum.map(&video_to_item/1)
      else
        []
      end

    (plans ++ videos)
    |> apply_filters(filters)
    |> sort_items()
  end

  # ---------------------------------------------------------------------------
  # Private — conversion
  # ---------------------------------------------------------------------------

  defp plan_to_item(user, plan) do
    %{burpee_count_total: count, duration_sec_total: duration} = Planner.summary(plan)
    level = Levels.level_for_count(plan.burpee_type, count)
    last_used = last_used_at(user, plan.id)

    %WorkoutItem{
      kind: :plan,
      id: plan.id,
      title: plan.name,
      burpee_type: plan.burpee_type,
      level: level,
      burpee_count: count,
      duration_sec: round(duration),
      start_path: "/session/#{plan.id}",
      edit_path: "/plans/#{plan.id}/edit",
      last_used_at: last_used,
      inserted_at: plan.inserted_at
    }
  end

  defp video_to_item(video) do
    level =
      if video.burpee_count do
        Levels.level_for_count(video.burpee_type, video.burpee_count)
      else
        nil
      end

    %WorkoutItem{
      kind: :video,
      id: video.id,
      title: video.name,
      burpee_type: video.burpee_type,
      level: level,
      burpee_count: video.burpee_count,
      duration_sec: video.duration_sec,
      start_path: "/videos/#{video.id}",
      edit_path: nil,
      last_used_at: nil,
      inserted_at: video.inserted_at
    }
  end

  # ---------------------------------------------------------------------------
  # Private — filtering
  # ---------------------------------------------------------------------------

  defp apply_filters(items, filters) do
    items
    |> filter_burpee_type(Map.get(filters, :burpee_type))
    |> filter_level(Map.get(filters, :level))
  end

  defp filter_burpee_type(items, nil), do: items
  defp filter_burpee_type(items, bt), do: Enum.filter(items, &(&1.burpee_type == bt))

  defp filter_level(items, nil), do: items
  defp filter_level(items, level), do: Enum.filter(items, &(&1.level == level))

  # ---------------------------------------------------------------------------
  # Private — sorting
  # ---------------------------------------------------------------------------

  defp sort_items(items) do
    Enum.sort_by(items, &item_sort_key/1)
  end

  # Plans come first (0), videos second (1)
  defp item_sort_key(%WorkoutItem{kind: :plan} = item) do
    {0, plan_sort_key(item)}
  end

  defp item_sort_key(%WorkoutItem{kind: :video} = item) do
    inserted_secs = to_unix(item.inserted_at)
    {1, {inserted_secs}}
  end

  defp plan_sort_key(item) do
    used_rank = if item.last_used_at, do: 0, else: 1
    used_secs = if item.last_used_at, do: -to_unix(item.last_used_at), else: 0
    inserted_secs = -to_unix(item.inserted_at)
    burpee_count = item.burpee_count || 0
    {used_rank, used_secs, burpee_count, inserted_secs}
  end

  # Handle both DateTime and NaiveDateTime (WorkoutVideo uses NaiveDateTime timestamps)
  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp to_unix(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
  end

  # ---------------------------------------------------------------------------
  # Private — DB helpers
  # ---------------------------------------------------------------------------

  defp last_used_at(%User{id: user_id}, plan_id) do
    Repo.one(
      from s in WorkoutSession,
        where: s.user_id == ^user_id and s.plan_id == ^plan_id,
        order_by: [desc: s.inserted_at],
        limit: 1,
        select: s.inserted_at
    )
  end
end
