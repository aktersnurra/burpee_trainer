defmodule BurpeeTrainer.Coach.Catalog do
  alias BurpeeTrainer.Levels

  def default_filters(level) do
    levels = Enum.reverse(Levels.all_levels())
    index = Enum.find_index(levels, &(&1 == level))

    %{
      types: MapSet.new([:six_count, :navy_seal]),
      levels: MapSet.new(Enum.slice(levels, index, 2))
    }
  end

  def plan_level(p), do: Levels.level_for_count(p.burpee_type, p.target_reps)

  def video_level(%{burpee_count: n, burpee_type: t}) when is_integer(n) and n > 0,
    do: Levels.level_for_count(t, n)

  def video_level(_), do: nil

  def filter(items, filters, level_fun),
    do:
      Enum.filter(items, fn item ->
        MapSet.member?(filters.types, item.burpee_type) and
          MapSet.member?(filters.levels, level_fun.(item))
      end)

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

  def order_videos(videos),
    do:
      videos
      |> Enum.reject(&(video_level(&1) == nil))
      |> Enum.sort_by(&{index(video_level(&1)), String.downcase(&1.name), &1.id})

  defp index(level), do: Enum.find_index(Enum.reverse(Levels.all_levels()), &(&1 == level))
end
