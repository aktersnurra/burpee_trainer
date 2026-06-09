defmodule BurpeeTrainer.Planning.DraftGenerator do
  @moduledoc "Generates human-readable planning drafts from goals."

  alias BurpeeTrainer.Planning.{Draft, Goal, TimelineItem}

  @burpee_duration_sec %{six_count: 3.0, navy_seal: 5.0}

  @spec generate(Goal.t()) :: {:ok, Draft.t()} | {:error, term()}
  def generate(%Goal{style: :even} = goal) do
    preferred_unit_sec = goal.preferred_unit_sec || 120
    unit_count = choose_unit_count(goal.duration_sec, goal.target_reps, preferred_unit_sec)
    unit_sec = unit_duration_sec(goal.duration_sec, unit_count, preferred_unit_sec)

    timeline = build_even_timeline(goal, unit_sec, unit_count)
    {timeline, feedback, changed_item_ids} = maybe_insert_requested_rest(timeline, goal)

    {:ok,
     %Draft{
       goal: goal,
       status: if(feedback, do: :adjusted, else: :good),
       timeline: timeline,
       feedback: feedback,
       changed_item_ids: changed_item_ids,
       metadata: %{generator: :even_units_v1, unit_sec: unit_sec}
     }}
  end

  def generate(%Goal{style: :unbroken} = goal) do
    set_size = goal.max_reps_per_set
    set_count = ceil(goal.target_reps / set_size)
    burpee_duration_sec = Map.fetch!(@burpee_duration_sec, goal.burpee_type)

    set_reps =
      0..(set_count - 1)
      |> Enum.map(fn index ->
        remaining_reps = goal.target_reps - index * set_size
        min(set_size, remaining_reps)
      end)

    work_sec = Enum.sum(set_reps) * burpee_duration_sec
    rest_budget_sec = max(round(goal.duration_sec - work_sec), 0)
    gap_count = max(set_count - 1, 0)
    base_rest_sec = if gap_count == 0, do: 0, else: div(rest_budget_sec, gap_count)
    extra_rest_sec = if gap_count == 0, do: 0, else: rem(rest_budget_sec, gap_count)

    {timeline, _cursor_sec} =
      set_reps
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {reps, index}, {items, cursor_sec} ->
        rest_after_sec =
          cond do
            index == set_count - 1 -> 0
            index < extra_rest_sec -> base_rest_sec + 1
            true -> base_rest_sec
          end

        item = %TimelineItem.UnbrokenGroup{
          id: "set-#{index + 1}",
          start_sec: cursor_sec,
          reps: reps,
          burpee_duration_sec: burpee_duration_sec,
          rest_after_sec: rest_after_sec
        }

        next_cursor_sec = cursor_sec + round(reps * burpee_duration_sec) + rest_after_sec
        {[item | items], next_cursor_sec}
      end)

    {:ok,
     %Draft{
       goal: goal,
       status: :good,
       timeline: Enum.reverse(timeline),
       metadata: %{generator: :unbroken_sets_v1, max_reps_per_set: set_size}
     }}
  end

  defp choose_unit_count(duration_sec, target_reps, preferred_unit_sec) do
    preferred_units = div(duration_sec, preferred_unit_sec)

    cond do
      preferred_units == 0 -> 1
      target_reps < preferred_units -> target_reps
      true -> preferred_units
    end
  end

  defp unit_duration_sec(duration_sec, unit_count, preferred_unit_sec) do
    cond do
      unit_count == 1 and duration_sec < preferred_unit_sec -> duration_sec
      rem(duration_sec, unit_count) == 0 -> div(duration_sec, unit_count)
      true -> duration_sec / unit_count
    end
  end

  defp build_even_timeline(_goal, _unit_sec, 0), do: []

  defp build_even_timeline(goal, unit_sec, unit_count) when unit_count > 0 do
    base_reps = div(goal.target_reps, unit_count)
    extra_reps = rem(goal.target_reps, unit_count)
    burpee_duration_sec = Map.fetch!(@burpee_duration_sec, goal.burpee_type)

    for index <- 0..(unit_count - 1) do
      reps = base_reps + if(index < extra_reps, do: 1, else: 0)
      interval = unit_sec / reps

      %TimelineItem.EvenUnit{
        id: "unit-#{index + 1}",
        start_sec: index * unit_sec,
        duration_sec: unit_sec,
        reps: reps,
        rep_interval_sec: interval,
        burpee_duration_sec: burpee_duration_sec
      }
    end
  end

  defp maybe_insert_requested_rest(timeline, %{requested_rest: nil}), do: {timeline, nil, []}

  defp maybe_insert_requested_rest(timeline, %{
         requested_rest: %{target_sec: target_sec, duration_sec: duration_sec}
       }) do
    funded_by =
      timeline
      |> Enum.filter(&(&1.start_sec < target_sec))
      |> Enum.map(& &1.id)

    tightened =
      Enum.map(timeline, fn
        %TimelineItem.EvenUnit{start_sec: start_sec, duration_sec: unit_duration_sec} = item
        when start_sec < target_sec and funded_by != [] ->
          funded_share = duration_sec / length(funded_by)
          new_duration = max(round(unit_duration_sec - funded_share), 1)
          %{item | duration_sec: new_duration, rep_interval_sec: new_duration / item.reps}

        item ->
          item
      end)

    rest = %TimelineItem.StandaloneRest{
      id: "rest-#{target_sec}",
      start_sec: 0,
      duration_sec: duration_sec,
      funded_by: funded_by
    }

    ordered_timeline =
      tightened
      |> Enum.sort_by(& &1.start_sec)
      |> insert_rest_after_funded(target_sec, rest)
      |> reflow_start_secs()

    feedback = %BurpeeTrainer.Planning.Feedback.Message{
      kind: :adjusted,
      text: "Added #{duration_sec}s reset · earlier units tightened to fund it",
      changed_item_ids: funded_by
    }

    {ordered_timeline, feedback, funded_by}
  end

  defp insert_rest_after_funded(timeline, target_sec, rest) do
    {earlier, later} = Enum.split_while(timeline, &(&1.start_sec < target_sec))
    earlier ++ [rest | later]
  end

  defp reflow_start_secs(timeline) do
    {_cursor, items} =
      Enum.reduce(timeline, {0, []}, fn
        %TimelineItem.EvenUnit{} = item, {cursor, acc} ->
          item = %{item | start_sec: cursor}
          {cursor + item.duration_sec, [item | acc]}

        %TimelineItem.StandaloneRest{} = item, {cursor, acc} ->
          item = %{item | start_sec: cursor}
          {cursor + item.duration_sec, [item | acc]}

        %TimelineItem.UnbrokenGroup{} = item, {cursor, acc} ->
          item = %{item | start_sec: cursor}
          next_cursor = cursor + round(item.reps * item.burpee_duration_sec) + item.rest_after_sec
          {next_cursor, [item | acc]}
      end)

    Enum.reverse(items)
  end
end
