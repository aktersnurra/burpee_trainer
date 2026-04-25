defmodule BurpeeTrainer.PlanWizard do
  @moduledoc """
  Pure functional plan generator. Converts a `WizardInput` into a
  fully-structured `%WorkoutPlan{}` ready for editor review (unsaved).

  No Ecto, no side effects. All inputs are plain data, all outputs are
  plain structs.

  Two pacing styles:
    `:even`     — equal sets, uniform cadence (all rest absorbed into
                  sec_per_rep); repeat_count optimisation when sets divide
                  cleanly.
    `:unbroken` — large sets with micro-rests between them and a longer
                  rest every `sets_per_group` sets.

  `extra_rest` inserts a longer pause at the workout boundary closest to
  `at_sec` seconds in. The planner shaves the cadence (even) or reduces
  end-of-set rests (unbroken) to keep the total within `duration_sec_total`.
  Returns `{:error, reasons}` if the shave would breach the floor
  (cadence can never go below `sec_per_burpee`).
  """

  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  defmodule WizardInput do
    @moduledoc false
    @enforce_keys [
      :duration_sec_total,
      :burpee_type,
      :burpee_count_total,
      :sec_per_burpee,
      :pacing_style
    ]
    defstruct [
      :duration_sec_total,
      :burpee_type,
      :burpee_count_total,
      :sec_per_burpee,
      :pacing_style,
      # %{at_sec: integer, rest_sec: integer} | nil
      extra_rest: nil
    ]
  end

  @doc """
  Generate a `%WorkoutPlan{}` from a `%WizardInput{}`.
  Returns `{:ok, plan}` or `{:error, [reason_string]}`.
  """
  @spec generate(WizardInput.t()) ::
          {:ok, WorkoutPlan.t()} | {:error, [String.t()]}
  def generate(%WizardInput{} = input) do
    case validate(input) do
      :ok -> build_plan(input)
      {:error, _} = err -> err
    end
  end

  @doc """
  Validate a `%WizardInput{}`.
  Returns `:ok` or `{:error, [reason_string]}`.
  """
  @spec validate(WizardInput.t()) :: :ok | {:error, [String.t()]}
  def validate(%WizardInput{} = input) do
    errors =
      []
      |> validate_wizard_positive(:burpee_count_total, input.burpee_count_total)
      |> validate_wizard_positive(:duration_sec_total, input.duration_sec_total)
      |> validate_wizard_positive(:sec_per_burpee, input.sec_per_burpee)
      |> validate_wizard_work_fits(input)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_wizard_positive(errors, _field, v) when is_number(v) and v > 0, do: errors

  defp validate_wizard_positive(errors, field, _v),
    do: ["#{field} must be positive" | errors]

  defp validate_wizard_work_fits(errors, %{
         burpee_count_total: n,
         sec_per_burpee: s,
         duration_sec_total: d
       })
       when is_number(n) and is_number(s) and is_number(d) do
    work = n * s

    if work > d,
      do: ["work time (#{round(work)}s) exceeds total duration (#{d}s)" | errors],
      else: errors
  end

  defp validate_wizard_work_fits(errors, _input), do: errors

  defp build_plan(input) do
    with {:ok, blocks} <- build_plan_blocks(input) do
      {:ok,
       %WorkoutPlan{
         name: build_plan_name(input),
         burpee_type: input.burpee_type,
         warmup_enabled: false,
         rest_sec_warmup_between: 120,
         rest_sec_warmup_before_main: 180,
         blocks: blocks
       }}
    end
  end

  defp build_plan_blocks(%{pacing_style: :even} = input), do: build_plan_even(input)
  defp build_plan_blocks(%{pacing_style: :unbroken} = input), do: build_plan_unbroken(input)

  # ---------------------------------------------------------------------------
  # Even pacing
  # ---------------------------------------------------------------------------

  # Rest is absorbed entirely into sec_per_rep (cadence = duration / count).
  # When extra_rest is set, the planner shaves the cadence to make room.
  # Error if the shave would push cadence below sec_per_burpee.
  defp build_plan_even(input) do
    target_set_size = if input.burpee_type == :six_count, do: 10, else: 5
    set_count = max(1, round(input.burpee_count_total / target_set_size))
    base_reps = div(input.burpee_count_total, set_count)
    extras = rem(input.burpee_count_total, set_count)
    base_cadence = input.duration_sec_total / input.burpee_count_total

    with {:ok, after_block, extra_rest_total} <-
           build_plan_even_resolve_extra(input.extra_rest, set_count, extras, base_cadence, base_reps) do
      sec_per_rep = (input.duration_sec_total - extra_rest_total) / input.burpee_count_total

      if sec_per_rep < input.sec_per_burpee do
        max_shave = round((base_cadence - input.sec_per_burpee) * input.burpee_count_total)

        {:error,
         [
           "extra rest (#{extra_rest_total}s) exceeds available shave — " <>
             "floor is #{input.sec_per_burpee}s/rep, max shave is #{max_shave}s"
         ]}
      else
        blocks =
          if extras == 0 do
            [
              %Block{
                position: 1,
                repeat_count: set_count,
                sets: [build_plan_set(1, base_reps, input.sec_per_burpee, sec_per_rep, 0)]
              }
            ]
          else
            sets =
              for i <- 0..(set_count - 1) do
                reps = if i < extras, do: base_reps + 1, else: base_reps
                build_plan_set(i + 1, reps, input.sec_per_burpee, sec_per_rep, 0)
              end

            [%Block{position: 1, repeat_count: 1, sets: sets}]
          end

        {:ok, split_blocks(blocks, after_block, input.extra_rest)}
      end
    end
  end

  # Derives the split point (after_block) from at_sec and the total extra
  # rest cost so the cadence can be adjusted before blocks are built.
  defp build_plan_even_resolve_extra(nil, _set_count, _extras, _cadence, _base_reps) do
    {:ok, nil, 0}
  end

  defp build_plan_even_resolve_extra(
         %{at_sec: at_sec, rest_sec: rest_sec},
         set_count,
         0,
         base_cadence,
         base_reps
       ) do
    # Repeating block: each repeat takes base_reps * base_cadence seconds.
    time_per_repeat = base_reps * base_cadence
    after_block = max(1, min(round(at_sec / time_per_repeat), set_count - 1))
    {:ok, after_block, after_block * rest_sec}
  end

  defp build_plan_even_resolve_extra(
         %{at_sec: at_sec, rest_sec: rest_sec},
         set_count,
         extras,
         base_cadence,
         base_reps
       ) do
    # Multi-set block: find the set boundary closest to at_sec.
    cumulative = build_plan_even_cumulative_times(extras, base_reps, set_count, base_cadence)
    after_block = build_plan_even_nearest_boundary(cumulative, at_sec, set_count)
    # Fires exactly once (repeat_count = 1 for this branch).
    {:ok, after_block, rest_sec}
  end

  defp build_plan_even_cumulative_times(extras, base_reps, set_count, base_cadence) do
    {times, _} =
      Enum.map_reduce(0..(set_count - 2), 0.0, fn i, acc ->
        reps = if i < extras, do: base_reps + 1, else: base_reps
        t = acc + reps * base_cadence
        {t, t}
      end)

    times
  end

  defp build_plan_even_nearest_boundary([], _at_sec, _set_count), do: 1

  defp build_plan_even_nearest_boundary(cumulative, at_sec, set_count) do
    {_t, idx} =
      cumulative
      |> Enum.with_index()
      |> Enum.min_by(fn {t, _} -> abs(t - at_sec) end)

    max(1, min(idx + 1, set_count - 1))
  end

  # ---------------------------------------------------------------------------
  # Unbroken pacing
  # ---------------------------------------------------------------------------

  # Large sets with micro-rests between them and longer rests at group
  # boundaries. When extra_rest is set, the available group-boundary rest
  # is reduced (effective_duration = duration - rest_sec). Error if this
  # drives the boundary rests below the micro-rest floor.
  defp build_plan_unbroken(input) do
    {min_size, max_size} = if input.burpee_type == :six_count, do: {8, 15}, else: {3, 5}
    target_size = div(min_size + max_size, 2)
    micro_rest_sec = 4
    sets_per_group = 3

    set_count = max(1, round(input.burpee_count_total / target_size))
    group_count = max(1, ceil(set_count / sets_per_group))
    work_sec = input.burpee_count_total * input.sec_per_burpee
    intra_rest_total = micro_rest_sec * max(0, set_count - group_count)

    extra_sec = if input.extra_rest, do: input.extra_rest.rest_sec, else: 0
    effective_duration = input.duration_sec_total - extra_sec
    min_rest_needed = intra_rest_total + group_count * micro_rest_sec

    if effective_duration - work_sec < min_rest_needed do
      max_shave = round(input.duration_sec_total - work_sec - min_rest_needed)

      {:error,
       [
         "extra rest (#{extra_sec}s) exceeds available rest budget — " <>
           "max shave is #{max(0, max_shave)}s"
       ]}
    else
      remaining_rest = max(0.0, effective_duration - work_sec - intra_rest_total)
      longer_rest = max(micro_rest_sec, round(remaining_rest / group_count))

      base_reps = div(input.burpee_count_total, set_count)
      extras = rem(input.burpee_count_total, set_count)

      sets =
        for i <- 0..(set_count - 1) do
          reps = if i < extras, do: base_reps + 1, else: base_reps
          is_group_boundary = rem(i + 1, sets_per_group) == 0 or i == set_count - 1
          rest = if is_group_boundary, do: longer_rest, else: micro_rest_sec
          build_plan_set(i + 1, reps, input.sec_per_burpee, input.sec_per_burpee, rest)
        end

      blocks = [%Block{position: 1, repeat_count: 1, sets: sets}]
      {:ok, split_blocks(blocks, build_plan_unbroken_split_at(sets, input.extra_rest), input.extra_rest)}
    end
  end

  # Find the set boundary (1-indexed) closest to at_sec.
  defp build_plan_unbroken_split_at(_sets, nil), do: nil

  defp build_plan_unbroken_split_at(sets, %{at_sec: at_sec}) do
    set_count = length(sets)

    if set_count <= 1 do
      nil
    else
      cumulative =
        sets
        |> Enum.scan(0.0, fn s, acc -> acc + s.burpee_count * s.sec_per_rep + s.end_of_set_rest end)
        |> Enum.drop(-1)

      {_t, idx} =
        cumulative
        |> Enum.with_index()
        |> Enum.min_by(fn {t, _} -> abs(t - at_sec) end)

      max(1, min(idx + 1, set_count - 1))
    end
  end

  # ---------------------------------------------------------------------------
  # Block splitting (shared)
  # ---------------------------------------------------------------------------

  defp split_blocks(blocks, nil, _extra_rest), do: blocks
  defp split_blocks(blocks, _after_block, nil), do: blocks

  defp split_blocks([block | rest_blocks], after_block, %{rest_sec: rest_sec})
       when block.repeat_count > 1 do
    n = max(1, min(after_block, block.repeat_count - 1))
    block1 = %{block | position: 1, repeat_count: n, sets: boost_last_rest(block.sets, rest_sec)}
    block2 = %{block | position: 2, repeat_count: block.repeat_count - n}
    [block1, block2 | rest_blocks]
  end

  defp split_blocks([block | rest_blocks], after_block, %{rest_sec: rest_sec})
       when block.repeat_count == 1 and length(block.sets) > 1 do
    n = max(1, min(after_block, length(block.sets) - 1))
    {sets1, sets2} = Enum.split(block.sets, n)
    block1 = %{block | position: 1, sets: boost_last_rest(sets1, rest_sec)}

    block2 = %{
      block
      | position: 2,
        sets: Enum.with_index(sets2, 1) |> Enum.map(fn {s, i} -> %{s | position: i} end)
    }

    [block1, block2 | rest_blocks]
  end

  defp split_blocks(blocks, _after_block, _extra_rest), do: blocks

  defp boost_last_rest(sets, rest_sec) do
    List.update_at(sets, -1, fn s -> %{s | end_of_set_rest: s.end_of_set_rest + rest_sec} end)
  end

  defp build_plan_set(position, burpee_count, sec_per_burpee, sec_per_rep, end_of_set_rest) do
    %Set{
      position: position,
      burpee_count: burpee_count,
      sec_per_rep: sec_per_rep,
      sec_per_burpee: sec_per_burpee,
      end_of_set_rest: end_of_set_rest
    }
  end

  defp build_plan_name(%{pacing_style: :even}), do: "Even pacing plan"
  defp build_plan_name(%{pacing_style: :unbroken}), do: "Unbroken sets plan"
end
