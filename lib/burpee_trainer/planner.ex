defmodule BurpeeTrainer.Planner do
  @moduledoc """
  Pure functional planner. Converts a `%WorkoutPlan{}` (with preloaded
  blocks and sets) into an ordered timeline of timed `%Event{}` structs.

  No Ecto, no side effects. All inputs are plain structs, all outputs
  are plain data — fully unit-testable.

  Inter-block rest note: blocks are connected via the trailing
  `end_of_set_rest` of the final set in the preceding block. There is
  no separate inter-block rest field — this is by design.

  Shave-off note: when `shave_off_sec`/`shave_off_block_count` are set,
  each repetition of blocks 1..N has `shave_off_sec` subtracted from
  its last set's `end_of_set_rest`. The accumulated saved seconds are
  emitted as a single `:shave_rest` event between block N and N+1.
  """

  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  defmodule Event do
    @moduledoc """
    A single timed event in a workout timeline.

    `type` is one of `:warmup_burpee`, `:warmup_rest`, `:work_burpee`,
    `:work_rest`, `:shave_rest`. `burpee_count` is `nil` for rest events.
    """

    @enforce_keys [:type, :duration_sec, :label]
    defstruct [:type, :duration_sec, :burpee_count, :label]

    @type kind ::
            :warmup_burpee
            | :warmup_rest
            | :work_burpee
            | :work_rest
            | :shave_rest

    @type t :: %__MODULE__{
            type: kind,
            duration_sec: float,
            burpee_count: integer | nil,
            label: String.t()
          }
  end

  @doc """
  Produces the full ordered event timeline for a plan.
  """
  @spec to_timeline(WorkoutPlan.t()) :: [Event.t()]
  def to_timeline(%WorkoutPlan{} = plan), do: build_timeline(plan)

  @doc """
  Distribute rest time across adjustable sets so the plan's total
  timeline duration matches `duration_sec_target`.

  "Adjustable" = `end_of_set_rest` on any set EXCEPT the final set of
  the final block (that rest is enforced to 0 elsewhere).

  Warmup rests and shave-off rest are left untouched — they have
  distinct meaning.

  Distribution strategy:
  - If the sum of adjustable rests is currently > 0: scale
    proportionally so relative rest feel is preserved.
  - If all adjustable rests are currently 0: split the delta evenly
    across each set-occurrence (weighted by `block.repeat_count`).

  Returns:
  - `{:ok, plan}` on success (rests are integer seconds, so the new
    total may drift by up to ~1s per adjustable set due to rounding).
  - `{:error, :no_adjustable_sets}` when nothing can be adjusted.
  - `{:error, :target_too_short}` when target is below the irreducible
    duration (all adjustable rests driven to 0 still exceeds it).
  """
  @spec fit_rest_to_duration(WorkoutPlan.t(), number) ::
          {:ok, WorkoutPlan.t()}
          | {:error, :no_adjustable_sets | :target_too_short}
  def fit_rest_to_duration(%WorkoutPlan{} = plan, duration_sec_target)
      when is_number(duration_sec_target) and duration_sec_target > 0 do
    blocks = sort_by_position(plan.blocks)
    adjustable_keys = fit_rest_adjustable_keys(blocks)

    cond do
      adjustable_keys == MapSet.new() ->
        {:error, :no_adjustable_sets}

      true ->
        current_total = summary(plan).duration_sec_total
        delta_target = duration_sec_target - current_total

        current_adjustable_rest = fit_rest_current_total(blocks, adjustable_keys)

        cond do
          delta_target == 0 ->
            {:ok, plan}

          current_adjustable_rest + delta_target < 0 ->
            {:error, :target_too_short}

          true ->
            new_rests =
              fit_rest_new_rests(
                blocks,
                adjustable_keys,
                current_adjustable_rest,
                delta_target
              )

            {:ok, fit_rest_apply(plan, blocks, new_rests)}
        end
    end
  end

  # Adjustable sets are identified by {block.position, set.position}. All
  # sets are adjustable EXCEPT the final set of the final block.
  defp fit_rest_adjustable_keys([]), do: MapSet.new()

  defp fit_rest_adjustable_keys(blocks) do
    last_block = List.last(blocks)
    last_sets = sort_by_position(last_block.sets)
    last_set = List.last(last_sets)

    for block <- blocks,
        set <- sort_by_position(block.sets),
        not (block.position == last_block.position and set.position == last_set.position),
        into: MapSet.new(),
        do: {block.position, set.position}
  end

  defp fit_rest_current_total(blocks, adjustable_keys) do
    for block <- blocks,
        set <- block.sets,
        MapSet.member?(adjustable_keys, {block.position, set.position}),
        reduce: 0 do
      acc -> acc + set.end_of_set_rest * block.repeat_count
    end
  end

  defp fit_rest_new_rests(blocks, adjustable_keys, current_total, delta_target)
       when current_total > 0 do
    scale = (current_total + delta_target) / current_total

    for block <- blocks,
        set <- block.sets,
        MapSet.member?(adjustable_keys, {block.position, set.position}),
        into: %{} do
      {{block.position, set.position}, max(round(set.end_of_set_rest * scale), 0)}
    end
  end

  defp fit_rest_new_rests(blocks, adjustable_keys, _current_total_zero, delta_target) do
    total_slots =
      for block <- blocks,
          set <- block.sets,
          MapSet.member?(adjustable_keys, {block.position, set.position}),
          reduce: 0 do
        acc -> acc + block.repeat_count
      end

    per_slot = if total_slots > 0, do: delta_target / total_slots, else: 0.0
    rest_value = max(round(per_slot), 0)

    for block <- blocks,
        set <- block.sets,
        MapSet.member?(adjustable_keys, {block.position, set.position}),
        into: %{} do
      {{block.position, set.position}, rest_value}
    end
  end

  defp fit_rest_apply(plan, blocks, new_rests) do
    new_blocks =
      Enum.map(blocks, fn block ->
        new_sets =
          Enum.map(block.sets, fn set ->
            case Map.fetch(new_rests, {block.position, set.position}) do
              {:ok, rest} -> %{set | end_of_set_rest: rest}
              :error -> set
            end
          end)

        %{block | sets: new_sets}
      end)

    %{plan | blocks: new_blocks}
  end

  @doc """
  Returns totals and per-block breakdown for a plan.

  Shape:

      %{
        burpee_count_total: integer,  # work burpees only, excludes warmup
        duration_sec_total: float,    # entire timeline, includes warmup and shave
        blocks: [%{
          position: integer,
          repeat_count: integer,
          burpee_count_total: integer,
          duration_sec_work: float,
          duration_sec_rest: float
        }]
      }
  """
  @spec summary(WorkoutPlan.t()) :: map
  def summary(%WorkoutPlan{} = plan) do
    timeline = build_timeline(plan)

    burpee_count_total =
      timeline
      |> Enum.filter(&(&1.type == :work_burpee))
      |> Enum.reduce(0, fn event, acc -> acc + (event.burpee_count || 0) end)

    duration_sec_total =
      Enum.reduce(timeline, 0.0, fn event, acc -> acc + event.duration_sec end)

    blocks =
      plan.blocks
      |> sort_by_position()
      |> Enum.map(&summary_block/1)

    %{
      burpee_count_total: burpee_count_total,
      duration_sec_total: duration_sec_total,
      blocks: blocks
    }
  end

  # --- summary helpers ---

  defp summary_block(%Block{} = block) do
    sets = sort_by_position(block.sets)
    repeat_count = block.repeat_count

    burpee_count_total =
      Enum.reduce(sets, 0, fn set, acc -> acc + set.burpee_count end) * repeat_count

    duration_sec_work =
      Enum.reduce(sets, 0.0, fn set, acc -> acc + set.burpee_count * set.sec_per_rep end) *
        repeat_count

    duration_sec_rest =
      Enum.reduce(sets, 0, fn set, acc -> acc + set.end_of_set_rest end) * repeat_count

    %{
      position: block.position,
      repeat_count: repeat_count,
      burpee_count_total: burpee_count_total,
      duration_sec_work: duration_sec_work,
      duration_sec_rest: duration_sec_rest
    }
  end

  # --- timeline construction ---

  defp build_timeline(%WorkoutPlan{blocks: blocks}) when blocks in [nil, []], do: []

  defp build_timeline(%WorkoutPlan{} = plan) do
    build_timeline_warmup(plan) ++ build_timeline_main(plan)
  end

  defp build_timeline_warmup(%WorkoutPlan{warmup_enabled: enabled}) when enabled in [false, nil],
    do: []

  defp build_timeline_warmup(%WorkoutPlan{warmup_rounds: rounds, warmup_reps: reps})
       when is_nil(rounds) or is_nil(reps) or rounds <= 0 or reps <= 0,
       do: []

  defp build_timeline_warmup(%WorkoutPlan{} = plan) do
    sec_per_rep = build_timeline_warmup_pace(plan)
    rounds = plan.warmup_rounds
    reps = plan.warmup_reps

    Enum.flat_map(1..rounds, fn round ->
      build_timeline_warmup_round(plan, round, rounds, reps, sec_per_rep)
    end)
  end

  defp build_timeline_warmup_round(plan, round, total_rounds, reps, sec_per_rep) do
    burpee_event = %Event{
      type: :warmup_burpee,
      duration_sec: reps * sec_per_rep,
      burpee_count: reps,
      label: "Warmup Round #{round}"
    }

    rest_duration =
      if round < total_rounds do
        plan.rest_sec_warmup_between || 0
      else
        plan.rest_sec_warmup_before_main || 0
      end

    if rest_duration > 0 do
      [
        burpee_event,
        %Event{
          type: :warmup_rest,
          duration_sec: rest_duration * 1.0,
          burpee_count: nil,
          label: "Warmup Rest"
        }
      ]
    else
      [burpee_event]
    end
  end

  defp build_timeline_warmup_pace(%WorkoutPlan{blocks: blocks}) do
    first_block = blocks |> sort_by_position() |> List.first()
    first_set = first_block.sets |> sort_by_position() |> List.first()
    first_set.sec_per_rep
  end

  defp build_timeline_main(%WorkoutPlan{} = plan) do
    blocks = sort_by_position(plan.blocks)
    shave_sec = shave_sec_effective(plan)
    shave_n = plan.shave_off_block_count || 0

    blocks
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {block, index} ->
      shave = if index <= shave_n, do: shave_sec, else: 0
      build_timeline_block(block, shave) ++ build_timeline_shave_rest(plan, blocks, index)
    end)
  end

  defp shave_sec_effective(%WorkoutPlan{shave_off_sec: sec, shave_off_block_count: n})
       when is_integer(sec) and sec > 0 and is_integer(n) and n > 0,
       do: sec

  defp shave_sec_effective(_), do: 0

  defp build_timeline_block(%Block{repeat_count: repeat_count}, _shave) when repeat_count <= 0,
    do: []

  defp build_timeline_block(%Block{} = block, shave_sec) do
    sets = sort_by_position(block.sets)
    last_set_index = length(sets)

    for round <- 1..block.repeat_count,
        {set, set_index} <- Enum.with_index(sets, 1),
        event <- build_timeline_block_set(block, round, set, set_index, last_set_index, shave_sec) do
      event
    end
  end

  defp build_timeline_block_set(
         %Block{} = block,
         round,
         %Set{} = set,
         set_index,
         last_set_index,
         shave_sec
       ) do
    work_event = %Event{
      type: :work_burpee,
      duration_sec: set.burpee_count * set.sec_per_rep,
      burpee_count: set.burpee_count,
      label: build_timeline_block_set_label(block, round, set_index)
    }

    rest_sec =
      if set_index == last_set_index,
        do: max(set.end_of_set_rest - shave_sec, 0),
        else: set.end_of_set_rest

    if rest_sec > 0 do
      [
        work_event,
        %Event{
          type: :work_rest,
          duration_sec: rest_sec * 1.0,
          burpee_count: nil,
          label: "Rest"
        }
      ]
    else
      [work_event]
    end
  end

  defp build_timeline_block_set_label(
         %Block{repeat_count: 1, position: block_pos},
         _round,
         set_index
       ) do
    "Block #{block_pos} · Set #{set_index}"
  end

  defp build_timeline_block_set_label(
         %Block{position: block_pos, repeat_count: repeat_count},
         round,
         set_index
       ) do
    "Block #{block_pos} · Round #{round}/#{repeat_count} · Set #{set_index}"
  end

  defp build_timeline_shave_rest(%WorkoutPlan{shave_off_sec: shave_sec}, _blocks, _index)
       when is_nil(shave_sec) or shave_sec <= 0,
       do: []

  defp build_timeline_shave_rest(%WorkoutPlan{shave_off_block_count: shave_n}, _blocks, _index)
       when is_nil(shave_n) or shave_n <= 0,
       do: []

  defp build_timeline_shave_rest(%WorkoutPlan{shave_off_block_count: shave_n}, _blocks, index)
       when index != shave_n,
       do: []

  defp build_timeline_shave_rest(%WorkoutPlan{} = plan, blocks, _index) do
    total_repetitions =
      blocks
      |> Enum.take(plan.shave_off_block_count)
      |> Enum.reduce(0, fn block, acc -> acc + block.repeat_count end)

    duration = plan.shave_off_sec * total_repetitions

    if duration > 0 do
      [
        %Event{
          type: :shave_rest,
          duration_sec: duration * 1.0,
          burpee_count: nil,
          label: "Shave-off Rest"
        }
      ]
    else
      []
    end
  end

  defp sort_by_position(nil), do: []
  defp sort_by_position(list) when is_list(list), do: Enum.sort_by(list, & &1.position)
end
