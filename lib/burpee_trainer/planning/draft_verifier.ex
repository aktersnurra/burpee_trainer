defmodule BurpeeTrainer.Planning.DraftVerifier do
  @moduledoc "Deterministic checks for solved planning drafts."

  alias BurpeeTrainer.Planning.Draft
  alias BurpeeTrainer.Planning.TimelineItem

  @duration_tolerance_sec 10
  @giant_even_unit_reps 100

  @spec verify(Draft.t()) :: :ok | {:error, [term()]}
  def verify(%Draft{} = draft) do
    errors =
      []
      |> verify_total_reps(draft)
      |> verify_duration(draft)
      |> verify_even_units(draft)
      |> verify_unbroken_groups(draft)

    case errors do
      [] -> :ok
      [_ | _] -> {:error, Enum.reverse(errors)}
    end
  end

  defp verify_total_reps(errors, draft) do
    total = Enum.reduce(draft.timeline, 0, &(&2 + reps(&1)))

    if total == draft.goal.target_reps do
      errors
    else
      [{:target_reps, {:expected, draft.goal.target_reps, :actual, total}} | errors]
    end
  end

  defp verify_duration(errors, draft) do
    duration = timeline_duration_sec(draft.timeline)

    if abs(duration - draft.goal.duration_sec) <= @duration_tolerance_sec do
      errors
    else
      [{:duration_sec, {:expected, draft.goal.duration_sec, :actual, duration}} | errors]
    end
  end

  defp verify_even_units(errors, %Draft{goal: %{style: :even}} = draft) do
    Enum.reduce(draft.timeline, errors, fn
      %TimelineItem.EvenUnit{reps: reps}, acc when reps >= @giant_even_unit_reps ->
        [{:timeline, :giant_even_unit} | acc]

      _item, acc ->
        acc
    end)
  end

  defp verify_even_units(errors, _draft), do: errors

  defp verify_unbroken_groups(
         errors,
         %Draft{goal: %{style: :unbroken, max_reps_per_set: max}} = draft
       ) do
    Enum.reduce(draft.timeline, errors, fn
      %TimelineItem.UnbrokenGroup{reps: reps}, acc when reps > max ->
        [{:unbroken_group, :exceeds_max_reps_per_set} | acc]

      _item, acc ->
        acc
    end)
  end

  defp verify_unbroken_groups(errors, _draft), do: errors

  defp reps(%TimelineItem.EvenUnit{reps: reps}), do: reps
  defp reps(%TimelineItem.UnbrokenGroup{reps: reps}), do: reps

  defp reps(%TimelineItem.MeaningfulPattern{repeat_count: repeat_count, pattern: pattern}) do
    repeat_count * Enum.sum(pattern)
  end

  defp reps(%TimelineItem.StandaloneRest{}), do: 0

  defp timeline_duration_sec([]), do: 0

  defp timeline_duration_sec(items) do
    items
    |> Enum.map(&item_end_sec/1)
    |> Enum.max()
  end

  defp item_end_sec(%TimelineItem.EvenUnit{} = item), do: item.start_sec + item.duration_sec
  defp item_end_sec(%TimelineItem.StandaloneRest{} = item), do: item.start_sec + item.duration_sec

  defp item_end_sec(%TimelineItem.MeaningfulPattern{} = item) do
    item.start_sec + item.repeat_count * (item.unit_duration_sec || 0)
  end

  defp item_end_sec(%TimelineItem.UnbrokenGroup{} = item) do
    item.start_sec + round(item.reps * item.burpee_duration_sec) + item.rest_after_sec
  end
end
