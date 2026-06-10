defmodule BurpeeTrainer.PlanEditor.Segments do
  @moduledoc """
  A workout plan structure as the user thinks of it: an ordered list of
  work segments (`N×[reps, ...]`) and rest segments.

  The plan editor edits this list directly. `balance/3` re-derives pace
  and per-set recovery deterministically from the targets so the
  executable duration is exact, and reports precisely what blocks a
  save together with one-tap fixes. `to_plan_attrs/3` materializes the
  segments into `blocks` + `steps` attrs for `Workouts.change_plan/2`.
  """

  alias BurpeeTrainer.{PlanNotation, PlanSolver}
  alias BurpeeTrainer.PlanSolver.Input
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @min_useful_recovery_sec 8
  @default_rest_sec 30

  @type work :: %{kind: :work, repeat: pos_integer(), pattern: [pos_integer()]}
  @type rest :: %{kind: :rest, rest_sec: pos_integer()}
  @type t :: [work() | rest()]

  @type fix :: %{kind: atom(), label: String.t(), value: integer() | nil}
  @type problem :: %{kind: atom(), blocking: boolean(), message: String.t(), fixes: [fix()]}

  @type balance :: %{
          ok?: boolean(),
          reps: non_neg_integer(),
          set_count: non_neg_integer(),
          pace: float(),
          movement_pace: float(),
          recovery_sec: non_neg_integer(),
          explicit_rest_sec: non_neg_integer(),
          duration_sec: float(),
          problems: [problem()]
        }

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @spec from_plan(WorkoutPlan.t()) :: t()
  def from_plan(%WorkoutPlan{} = plan) do
    blocks = plan.blocks |> loaded() |> Enum.sort_by(& &1.position)
    blocks_by_position = Map.new(blocks, &{&1.position, &1})
    steps = plan.steps |> loaded() |> Enum.sort_by(& &1.position)

    segments =
      if steps == [] do
        Enum.map(blocks, &%{kind: :work, repeat: &1.repeat_count || 1, pattern: pattern_of(&1)})
      else
        Enum.flat_map(steps, fn
          %{kind: :block_run} = step ->
            case blocks_by_position[step.block_position] do
              nil ->
                []

              block ->
                [%{kind: :work, repeat: step.repeat_count || 1, pattern: pattern_of(block)}]
            end

          %{kind: :rest} = step ->
            [%{kind: :rest, rest_sec: step.rest_sec || @default_rest_sec}]
        end)
      end

    merge_adjacent_work(segments)
  end

  @spec from_solution(PlanSolver.Solution.t()) :: t()
  def from_solution(%PlanSolver.Solution{plan: plan}), do: from_plan(plan)

  defp pattern_of(block) do
    block.sets
    |> loaded()
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&(&1.burpee_count || 0))
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: []
  defp loaded(list) when is_list(list), do: list
  defp loaded(_), do: []

  # Materialization splits work runs to absorb rest rounding; fold them back.
  defp merge_adjacent_work(segments) do
    Enum.reduce(segments, [], fn segment, acc ->
      case {List.last(acc), segment} do
        {%{kind: :work, pattern: pattern} = previous, %{kind: :work, pattern: pattern}} ->
          List.replace_at(acc, -1, %{previous | repeat: previous.repeat + segment.repeat})

        _ ->
          acc ++ [segment]
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @spec total_reps(t()) :: non_neg_integer()
  def total_reps(segments) do
    segments
    |> work_segments()
    |> Enum.reduce(0, fn segment, acc -> acc + segment.repeat * Enum.sum(segment.pattern) end)
  end

  @spec set_count(t()) :: non_neg_integer()
  def set_count(segments) do
    segments
    |> work_segments()
    |> Enum.reduce(0, fn segment, acc -> acc + segment.repeat * length(segment.pattern) end)
  end

  @spec explicit_rest_sec(t()) :: non_neg_integer()
  def explicit_rest_sec(segments) do
    segments
    |> Enum.filter(&(&1.kind == :rest))
    |> Enum.reduce(0, fn segment, acc -> acc + segment.rest_sec end)
  end

  @spec notation(t()) :: String.t()
  def notation(segments), do: PlanNotation.from_segments(segments)

  defp work_segments(segments), do: Enum.filter(segments, &(&1.kind == :work))

  # ---------------------------------------------------------------------------
  # Editing
  # ---------------------------------------------------------------------------

  @spec update_work(t(), non_neg_integer(), pos_integer() | nil, %{integer() => pos_integer()}) ::
          t()
  def update_work(segments, index, repeat, set_reps) do
    update_at_kind(segments, index, :work, fn segment ->
      pattern =
        segment.pattern
        |> Enum.with_index()
        |> Enum.map(fn {reps, set_index} -> Map.get(set_reps, set_index, reps) end)

      %{segment | repeat: repeat || segment.repeat, pattern: pattern}
    end)
  end

  @spec update_rest(t(), non_neg_integer(), pos_integer()) :: t()
  def update_rest(segments, index, rest_sec) do
    update_at_kind(segments, index, :rest, &%{&1 | rest_sec: rest_sec})
  end

  @spec add_set(t(), non_neg_integer()) :: t()
  def add_set(segments, index) do
    update_at_kind(segments, index, :work, fn segment ->
      %{segment | pattern: segment.pattern ++ [List.last(segment.pattern) || 1]}
    end)
  end

  @spec remove_set(t(), non_neg_integer(), non_neg_integer()) :: t()
  def remove_set(segments, index, set_index) do
    segments
    |> update_at_kind(index, :work, fn segment ->
      %{segment | pattern: List.delete_at(segment.pattern, set_index)}
    end)
    |> Enum.reject(&(&1.kind == :work and &1.pattern == []))
  end

  @spec insert_work(t(), integer(), pos_integer()) :: t()
  def insert_work(segments, after_index, default_reps) do
    pattern =
      segments
      |> work_segments()
      |> List.last()
      |> case do
        %{pattern: pattern} -> pattern
        nil -> [default_reps]
      end

    List.insert_at(segments, after_index + 1, %{kind: :work, repeat: 1, pattern: pattern})
  end

  @spec insert_rest(t(), integer()) :: t()
  def insert_rest(segments, after_index) do
    List.insert_at(segments, after_index + 1, %{kind: :rest, rest_sec: @default_rest_sec})
  end

  @spec remove_at(t(), non_neg_integer()) :: t()
  def remove_at(segments, index), do: List.delete_at(segments, index)

  @doc "Splits a repeated work segment in two so a rest can go between."
  @spec split_work(t(), non_neg_integer()) :: t()
  def split_work(segments, index) do
    case Enum.at(segments, index) do
      %{kind: :work, repeat: repeat} = segment when repeat > 1 ->
        first = ceil(repeat / 2)

        segments
        |> List.replace_at(index, %{segment | repeat: first})
        |> List.insert_at(index + 1, %{segment | repeat: repeat - first})

      _ ->
        segments
    end
  end

  defp update_at_kind(segments, index, kind, fun) do
    case Enum.at(segments, index) do
      %{kind: ^kind} = segment -> List.replace_at(segments, index, fun.(segment))
      _ -> segments
    end
  end

  # ---------------------------------------------------------------------------
  # Balance & validation
  # ---------------------------------------------------------------------------

  @doc """
  Derives pace and recovery from the targets for the given structure.

  Recovery is an integer number of seconds per set gap; the cadence is
  then adjusted so the executable duration is exactly the target. All
  problems carry one-tap fixes.
  """
  @spec balance(t(), map(), atom()) :: balance()
  def balance(segments, input, level) do
    reps = total_reps(segments)
    sets = set_count(segments)
    explicit = explicit_rest_sec(segments)
    target_sec = input.target_duration_min * 60
    budget = target_sec - explicit
    ceiling = ceiling(input, level, reps)
    gaps = max(sets - 1, 0)

    {pace, recovery} = solve_pace(input.pacing_style, reps, budget, ceiling, gaps)

    problems =
      []
      |> add_empty_problem(reps)
      |> add_time_problem(input, reps, budget, ceiling, gaps, pace)
      |> add_recovery_problem(input.pacing_style, recovery, gaps, pace)
      |> add_mismatch_problem(input, reps)

    %{
      ok?: not Enum.any?(problems, & &1.blocking),
      reps: reps,
      set_count: sets,
      pace: pace,
      movement_pace: Float.round(min(ceiling, pace) * 1.0, 3),
      recovery_sec: recovery,
      explicit_rest_sec: explicit,
      duration_sec: reps * pace + gaps * recovery + explicit,
      problems: problems
    }
  end

  defp solve_pace(_style, 0, _budget, ceiling, _gaps), do: {ceiling, 0}

  defp solve_pace(:even, reps, budget, _ceiling, _gaps), do: {max(budget, 0) / reps, 0}

  defp solve_pace(:unbroken, reps, budget, ceiling, gaps) do
    cond do
      budget < reps * ceiling -> {ceiling, 0}
      gaps == 0 -> {budget / reps, 0}
      true -> integer_recovery(reps, budget, ceiling, gaps)
    end
  end

  # Round recovery to whole seconds, then absorb the difference in the
  # cadence so the total still lands exactly on the target.
  defp integer_recovery(reps, budget, ceiling, gaps) do
    ideal = (budget - reps * ceiling) / gaps
    rounded = round(ideal)
    recovery = if (budget - gaps * rounded) / reps < ceiling, do: trunc(ideal), else: rounded
    recovery = max(recovery, 0)
    {(budget - gaps * recovery) / reps, recovery}
  end

  defp ceiling(input, level, reps) do
    PlanSolver.effective_ceiling(%Input{
      name: input.name,
      burpee_type: input.burpee_type,
      target_duration_min: input.target_duration_min,
      burpee_count_target: max(reps, 1),
      pacing_style: input.pacing_style,
      level: level,
      sec_per_burpee_override: input.sec_per_burpee_override
    })
  end

  defp add_empty_problem(problems, 0) do
    problems ++
      [
        %{
          kind: :empty,
          blocking: true,
          message: "The workout has no sets yet. Add a block or regenerate from your targets.",
          fixes: [%{kind: :regenerate, label: "Regenerate", value: nil}]
        }
      ]
  end

  defp add_empty_problem(problems, _reps), do: problems

  defp add_time_problem(problems, _input, 0, _budget, _ceiling, _gaps, _pace), do: problems

  defp add_time_problem(problems, input, reps, budget, ceiling, gaps, _pace) do
    if budget < reps * ceiling do
      target_sec = input.target_duration_min * 60
      explicit = target_sec - budget
      min_duration_min = ceil((reps * ceiling + gaps * @min_useful_recovery_sec + explicit) / 60)

      max_reps =
        ((budget + @min_useful_recovery_sec) /
           (ceiling + @min_useful_recovery_sec / avg_set_size(reps, gaps)))
        |> floor()
        |> max(1)

      problems ++
        [
          %{
            kind: :no_time,
            blocking: true,
            message:
              "#{reps} reps at the safe pace of #{Float.round(ceiling, 1)}s/rep need " <>
                "more than #{input.target_duration_min} min" <>
                if(explicit > 0, do: " (#{explicit}s of it is rest)", else: "") <> ".",
            fixes: [
              %{kind: :duration, label: "Use #{min_duration_min} min", value: min_duration_min},
              %{kind: :reps, label: "Drop to #{max_reps} reps", value: max_reps}
            ]
          }
        ]
    else
      problems
    end
  end

  defp avg_set_size(reps, gaps), do: reps / max(gaps + 1, 1)

  defp add_recovery_problem(problems, :unbroken, recovery, gaps, _pace)
       when gaps > 0 and recovery < @min_useful_recovery_sec do
    problems ++
      [
        %{
          kind: :thin_recovery,
          blocking: false,
          message:
            "Only #{recovery}s of recovery between sets. Use larger sets, fewer reps, or more time.",
          fixes: []
        }
      ]
  end

  defp add_recovery_problem(problems, _style, _recovery, _gaps, _pace), do: problems

  defp add_mismatch_problem(problems, _input, 0), do: problems

  defp add_mismatch_problem(problems, input, reps) do
    if reps == input.burpee_count_target do
      problems
    else
      problems ++
        [
          %{
            kind: :reps_mismatch,
            blocking: true,
            message:
              "The blocks total #{reps} reps, but the target is #{input.burpee_count_target}.",
            fixes: [
              %{kind: :reps, label: "Make #{reps} the target", value: reps},
              %{kind: :regenerate, label: "Regenerate blocks", value: nil}
            ]
          }
        ]
    end
  end

  @doc "One-tap target fixes for when the solver itself finds no plan."
  @spec target_fixes(map(), atom()) :: [fix()]
  def target_fixes(input, level) do
    reps = input.burpee_count_target
    ceiling = ceiling(input, level, reps)
    explicit = Enum.reduce(input.additional_rests || [], 0, &(&1.rest_sec + &2))
    budget = input.target_duration_min * 60 - explicit

    gaps =
      case input.pacing_style do
        :unbroken -> max(ceil(reps / max(input.reps_per_set || 1, 1)) - 1, 0)
        :even -> 0
      end

    min_duration_min = ceil((reps * ceiling + gaps * @min_useful_recovery_sec + explicit) / 60)

    max_reps =
      (max(budget, 0) / (ceiling + @min_useful_recovery_sec / max(input.reps_per_set || 8, 1)))
      |> floor()
      |> max(1)

    fixes = [%{kind: :duration, label: "Use #{min_duration_min} min", value: min_duration_min}]

    if max_reps < reps do
      fixes ++ [%{kind: :reps, label: "Drop to #{max_reps} reps", value: max_reps}]
    else
      fixes
    end
  end

  # ---------------------------------------------------------------------------
  # Timeline preview
  # ---------------------------------------------------------------------------

  @doc "Start times and labels for a read-only timeline preview."
  @spec timeline(t(), balance()) :: [%{at_sec: number(), label: String.t(), kind: atom()}]
  def timeline(segments, balance) do
    {rows, elapsed} =
      Enum.map_reduce(segments, 0.0, fn segment, elapsed ->
        case segment do
          %{kind: :work} = work ->
            duration =
              work.repeat *
                (Enum.sum(work.pattern) * balance.pace +
                   length(work.pattern) * balance.recovery_sec)

            label = PlanNotation.from_segments([work])
            {%{at_sec: elapsed, label: label, kind: :work}, elapsed + duration}

          %{kind: :rest, rest_sec: rest_sec} ->
            {%{at_sec: elapsed, label: "Rest #{rest_sec}s", kind: :rest}, elapsed + rest_sec}
        end
      end)

    # The final set carries no recovery.
    finish = max(elapsed - balance.recovery_sec, 0.0)
    rows ++ [%{at_sec: finish, label: "Finish", kind: :finish}]
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  @doc """
  Materializes segments into plan attrs for `Workouts.change_plan/2`.

  Every set gets the balanced recovery except the very last set of the
  workout, which gets none — splitting the final work segment when it
  repeats — so the executable duration matches the target exactly.
  """
  @spec to_plan_attrs(t(), map(), balance()) :: map()
  def to_plan_attrs(segments, input, balance) do
    work_units = materialize_work_units(segments, input.pacing_style, balance)

    {block_attrs, step_attrs, rest_attrs, _} =
      Enum.reduce(work_units, {[], [], [], 0.0}, fn unit, {blocks, steps, rests, elapsed} ->
        case unit do
          %{kind: :work} = work ->
            position = length(blocks) + 1

            sets =
              work.set_specs
              |> Enum.with_index(1)
              |> Enum.map(fn {{reps, rest_sec}, set_position} ->
                %{
                  "position" => set_position,
                  "burpee_count" => reps,
                  "sec_per_rep" => balance.pace,
                  "sec_per_burpee" => balance.movement_pace,
                  "end_of_set_rest" => rest_sec
                }
              end)

            block = %{
              "position" => position,
              "repeat_count" => work.repeat,
              "sets" => sets
            }

            step = %{
              "position" => length(steps) + 1,
              "kind" => "block_run",
              "block_position" => position,
              "repeat_count" => work.repeat
            }

            duration =
              work.repeat *
                Enum.reduce(work.set_specs, 0.0, fn {reps, rest_sec}, acc ->
                  acc + reps * balance.pace + rest_sec
                end)

            {blocks ++ [block], steps ++ [step], rests, elapsed + duration}

          %{kind: :rest, rest_sec: rest_sec} ->
            step = %{
              "position" => length(steps) + 1,
              "kind" => "rest",
              "rest_sec" => rest_sec
            }

            target_min = elapsed |> Kernel./(60) |> round() |> max(1)
            rest = %{rest_sec: rest_sec, target_min: target_min}
            {blocks, steps ++ [step], rests ++ [rest], elapsed + rest_sec}
        end
      end)

    %{
      "name" => input.name,
      "burpee_type" => Atom.to_string(input.burpee_type),
      "target_duration_min" => input.target_duration_min,
      "burpee_count_target" => input.burpee_count_target,
      "sec_per_burpee" => balance.movement_pace,
      "pacing_style" => Atom.to_string(input.pacing_style),
      "additional_rests" => Jason.encode!(rest_attrs),
      "blocks" => block_attrs,
      "steps" => step_attrs
    }
  end

  # Expands segments into units carrying per-set trailing rest, splitting
  # the final work segment so only the workout's last set drops its rest.
  defp materialize_work_units(segments, pacing_style, balance) do
    recovery = if pacing_style == :unbroken, do: balance.recovery_sec, else: 0
    last_work_index = segments |> Enum.with_index() |> last_work_index()

    segments
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{kind: :work} = work, index} when index == last_work_index ->
        split_final_work(work, recovery)

      {%{kind: :work} = work, _index} ->
        [%{kind: :work, repeat: work.repeat, set_specs: Enum.map(work.pattern, &{&1, recovery})}]

      {%{kind: :rest} = rest, _index} ->
        [rest]
    end)
  end

  defp last_work_index(indexed_segments) do
    indexed_segments
    |> Enum.filter(fn {segment, _index} -> segment.kind == :work end)
    |> List.last()
    |> case do
      {_segment, index} -> index
      nil -> nil
    end
  end

  defp split_final_work(%{repeat: repeat, pattern: pattern}, recovery) do
    with_rest = Enum.map(pattern, &{&1, recovery})
    final = List.update_at(with_rest, -1, fn {reps, _rest} -> {reps, 0} end)

    cond do
      repeat > 1 and recovery > 0 ->
        [
          %{kind: :work, repeat: repeat - 1, set_specs: with_rest},
          %{kind: :work, repeat: 1, set_specs: final}
        ]

      repeat > 1 ->
        [%{kind: :work, repeat: repeat, set_specs: final}]

      true ->
        [%{kind: :work, repeat: 1, set_specs: final}]
    end
  end
end
