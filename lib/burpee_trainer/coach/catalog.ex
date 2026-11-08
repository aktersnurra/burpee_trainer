defmodule BurpeeTrainer.Coach.Catalog do
  alias BurpeeTrainer.Coach.RepCeiling
  alias BurpeeTrainer.Levels

  @types [:six_count, :navy_seal]

  @doc "The drawer's filters as it opens: both types, the athlete's level and every one above."
  def default_filters(level) do
    levels = Enum.reverse(Levels.all_levels())
    %{types: MapSet.new(@types), levels: MapSet.new(Enum.drop(levels, index(level)))}
  end

  @doc "The items of a type and a level the filters keep."
  def filter(items, filters, level_fun),
    do:
      Enum.filter(items, fn item ->
        MapSet.member?(filters.types, item.burpee_type) and
          MapSet.member?(filters.levels, level_fun.(item))
      end)

  # A workout's level is that of the 20-minute session it is as good as, fatigue counted: a
  # 40-minute catch-up is not graded on its raw reps.
  def plan_level(p),
    do:
      Levels.level_for_count(p.burpee_type, RepCeiling.pace(p.target_reps, p.target_duration_sec))

  def video_level(%{burpee_count: n, burpee_type: t, duration_sec: d})
      when is_integer(n) and n > 0 and is_integer(d) and d > 0,
      do: Levels.level_for_count(t, RepCeiling.pace(n, d))

  def video_level(_), do: nil

  def order_plans(plans, ids, slot, level) do
    by_id = Map.new(plans, &{&1.id, &1})

    first =
      ids
      |> Enum.filter(&Map.has_key?(by_id, &1))
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(by_id, &1))

    used = MapSet.new(first, & &1.id)

    rest =
      plans
      |> Enum.reject(&MapSet.member?(used, &1.id))
      |> Enum.sort_by(fn p ->
        {if(p.burpee_type == slot.burpee_type, do: 0, else: 1),
         abs(p.target_duration_sec - slot.duration_sec), abs(index(plan_level(p)) - index(level)),
         String.downcase(p.name), p.id}
      end)

    first ++ rest
  end

  # Nearest the athlete's level first, as plans are.
  def order_videos(videos, level),
    do:
      videos
      |> Enum.reject(&(video_level(&1) == nil))
      |> Enum.sort_by(
        &{abs(index(video_level(&1)) - index(level)), index(video_level(&1)),
         String.downcase(&1.name), &1.id}
      )

  defp index(level), do: Enum.find_index(Enum.reverse(Levels.all_levels()), &(&1 == level))
end
