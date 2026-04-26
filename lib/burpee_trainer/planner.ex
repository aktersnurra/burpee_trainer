defmodule BurpeeTrainer.Planner do
  @moduledoc """
  Pure functional planner. Converts a `%WorkoutPlan{}` (with preloaded
  blocks and sets) into an ordered timeline of timed `%Event{}` structs.

  No Ecto, no side effects. All inputs are plain structs, all outputs
  are plain data — fully unit-testable.

  Inter-block rest: blocks are connected via the `end_of_set_rest` of the
  final set of the preceding block. There is no separate inter-block rest
  field — this is by design.

  Warmup is decoupled from plans. Call `warmup_timeline/1` separately and
  prepend to the main timeline if the user opts in.
  """

  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  defmodule Event do
    @moduledoc """
    A single timed event in a workout timeline.

    `type` is one of `:warmup_burpee`, `:warmup_rest`, `:work_burpee`,
    `:work_rest`, `:rest_block`. `burpee_count` is `nil` for rest events.
    """

    @enforce_keys [:type, :duration_sec, :label]
    defstruct [:type, :duration_sec, :burpee_count, :sec_per_burpee, :label]

    @type kind ::
            :warmup_burpee
            | :warmup_rest
            | :work_burpee
            | :work_rest
            | :rest_block

    @type t :: %__MODULE__{
            type: kind,
            duration_sec: float,
            burpee_count: integer | nil,
            sec_per_burpee: float | nil,
            label: String.t()
          }
  end

  @doc """
  Produces the full ordered event timeline for a plan (main work only,
  no warmup). Call `warmup_timeline/1` and prepend if the user opts in.
  """
  @spec to_timeline(WorkoutPlan.t()) :: [Event.t()]
  def to_timeline(%WorkoutPlan{} = plan), do: build_timeline_main(plan)

  @doc """
  Generates a two-round warmup timeline for a plan. The warmup rep count
  is the smaller of: the first set's burpee_count, and reps achievable in
  one minute at the plan's pace. Hardcoded rests: 120s between rounds,
  180s before main workout.

  Returns `[]` if no blocks/sets exist or if pace is 0.
  """
  @spec warmup_timeline(WorkoutPlan.t()) :: [Event.t()]
  def warmup_timeline(%WorkoutPlan{blocks: blocks} = plan) when is_list(blocks) and blocks != [] do
    first_block = blocks |> sort_by_position() |> List.first()
    first_set = first_block && first_block.sets |> sort_by_position() |> List.first()

    if is_nil(first_set) or first_set.sec_per_burpee <= 0 do
      []
    else
      sec_per_burpee = plan.sec_per_burpee || first_set.sec_per_burpee
      warmup_reps = min(first_set.burpee_count, trunc(60.0 / sec_per_burpee))

      if warmup_reps <= 0 do
        []
      else
        dur = warmup_reps * sec_per_burpee

        [
          %Event{type: :warmup_burpee, duration_sec: dur, burpee_count: warmup_reps, sec_per_burpee: sec_per_burpee, label: "Warmup Round 1"},
          %Event{type: :warmup_rest, duration_sec: 120.0, burpee_count: nil, sec_per_burpee: nil, label: "Warmup Rest"},
          %Event{type: :warmup_burpee, duration_sec: dur, burpee_count: warmup_reps, sec_per_burpee: sec_per_burpee, label: "Warmup Round 2"},
          %Event{type: :warmup_rest, duration_sec: 180.0, burpee_count: nil, sec_per_burpee: nil, label: "Warmup Rest"}
        ]
      end
    end
  end

  def warmup_timeline(_), do: []

  @doc """
  Distribute rest time across adjustable sets so the plan's total
  timeline duration matches `duration_sec_target`.

  "Adjustable" = `end_of_set_rest` on any set EXCEPT the final set of
  the final block (that rest is enforced to 0 elsewhere).

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
        burpee_count_total: integer,
        duration_sec_total: float,
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
    timeline = build_timeline_main(plan)

    burpee_count_total =
      timeline
      |> Enum.filter(&(&1.type == :work_burpee))
      |> Enum.reduce(0, fn event, acc -> acc + (event.burpee_count || 0) end)

    duration_sec_total =
      Enum.reduce(plan.blocks, 0.0, fn block, acc ->
        duration_block =
          Enum.reduce(block.sets, 0.0, fn set, inner ->
            inner + set.burpee_count * set.sec_per_rep + set.end_of_set_rest
          end)

        acc + duration_block * block.repeat_count
      end)

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

  defp build_timeline_main(%WorkoutPlan{blocks: blocks}) when blocks in [nil, []], do: []

  defp build_timeline_main(%WorkoutPlan{} = plan) do
    plan.blocks
    |> sort_by_position()
    |> Enum.flat_map(&build_timeline_block/1)
  end

  defp build_timeline_block(%Block{repeat_count: repeat_count}) when repeat_count <= 0,
    do: []

  defp build_timeline_block(%Block{} = block) do
    sets = sort_by_position(block.sets)
    last_set_index = length(sets)

    for round <- 1..block.repeat_count,
        {set, set_index} <- Enum.with_index(sets, 1),
        event <- build_timeline_set(block, round, set, set_index, last_set_index) do
      event
    end
  end

  defp build_timeline_set(%Block{} = block, round, %Set{} = set, set_index, last_set_index) do
    work_event = %Event{
      type: :work_burpee,
      duration_sec: set.burpee_count * set.sec_per_rep,
      burpee_count: set.burpee_count,
      sec_per_burpee: set.sec_per_rep,
      label: build_set_label(block, round, set_index)
    }

    rest_sec = set.end_of_set_rest

    if rest_sec > 0 and set_index <= last_set_index do
      [
        work_event,
        %Event{type: :work_rest, duration_sec: rest_sec * 1.0, burpee_count: nil, sec_per_burpee: nil, label: "Rest"}
      ]
    else
      [work_event]
    end
  end

  defp build_set_label(%Block{position: block_pos}, _round, _set_index) do
    "Block #{block_pos}"
  end

  defp sort_by_position(nil), do: []
  defp sort_by_position(list) when is_list(list), do: Enum.sort_by(list, & &1.position)
end
