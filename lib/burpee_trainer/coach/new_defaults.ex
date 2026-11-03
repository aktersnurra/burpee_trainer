defmodule BurpeeTrainer.Coach.NewDefaults do
  @moduledoc """
  What the New workout steps start from, so each is one swipe from right: a duration no
  longer than the week has left (and never past its 80 minutes), the reps this athlete can
  do in it, and the movement pace that fits them.

  The functions without a scope are pure; `suggested_reps/3` reads the athlete's progression.
  """

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Progression, RepCeiling, WorkoutGuidance}
  alias BurpeeTrainer.Levels

  @standard_min 20
  @step_min 5
  @week_max_min 80
  @rep_step 5
  @big_rep_steps_from 50
  @pace_step 0.5
  # Beyond a standard session the same pace is not held for longer.
  @long_session_factor 0.9
  # Without a history the movement fills this share of the time; the rest is recovery.
  @work_share 0.85

  @doc """
  The durations a session can take, in minutes: steps of five up to what is left of the
  week, which itself is always one of them. `remaining_sec: nil` means unknown, and allows
  the whole week.
  """
  @spec durations(non_neg_integer() | nil) :: [pos_integer()]
  def durations(remaining_sec) do
    max_min = remaining_sec |> max_minutes() |> min(@week_max_min)
    steps = if max_min >= @step_min, do: Enum.to_list(@step_min..max_min//@step_min), else: []
    Enum.uniq(steps ++ [max_min])
  end

  @doc "The duration to start from: a standard session, or what is left if that is less."
  @spec default_duration(non_neg_integer() | nil) :: pos_integer()
  def default_duration(remaining_sec), do: min(@standard_min, List.last(durations(remaining_sec)))

  @doc "The next duration up or down the list, staying at its ends."
  @spec step_duration(pos_integer(), :up | :down, non_neg_integer() | nil) :: pos_integer()
  def step_duration(minutes, direction, remaining_sec) do
    options = durations(remaining_sec)

    case direction do
      :up -> Enum.find(options, List.last(options), &(&1 > minutes))
      :down -> options |> Enum.reverse() |> Enum.find(List.first(options), &(&1 < minutes))
    end
  end

  @doc """
  The reps to start from for `duration_sec`, a little past what the athlete has shown: one
  step above their best 20-minute pace of the last eight weeks, never beyond the 10% the
  planner allows, scaled to the duration. When their latest session says to ease off, the
  eased rate instead. With no recent session it is the next level's landmark.
  """
  @spec suggested_reps(Scope.t(), atom(), pos_integer()) :: pos_integer()
  def suggested_reps(%Scope{} = scope, burpee_type, duration_sec) do
    best = RepCeiling.recent_bests(scope)[burpee_type]

    case Progression.for_type(scope, burpee_type) do
      %Progression{action: :ease, max_reps_per_20: eased} when is_integer(eased) ->
        eased |> scale(duration_sec) |> snap(@rep_step)

      _no_ease when is_integer(best) ->
        pushed(best, duration_sec)

      _none ->
        scope |> landmark_rate(burpee_type) |> scale(duration_sec) |> snap(@rep_step)
    end
  end

  @doc """
  One step past `best` reps per 20 minutes, within 10% of it, for `duration_sec`: rounded to
  five when that still beats the best, otherwise to the rep.
  """
  @spec pushed(pos_integer(), pos_integer()) :: pos_integer()
  def pushed(best, duration_sec) do
    target = best |> snap(@rep_step) |> step_reps(:up) |> min(div(best * 110, 100)) |> max(best)
    reps = scale(target, duration_sec)
    rounded = floor(reps / @rep_step) * @rep_step

    if rounded > scale(best, duration_sec), do: rounded, else: max(round(reps), 1)
  end

  @doc """
  The reps one step up or down: five at a time up to #{@big_rep_steps_from}, ten from there, so
  a hundred is five steps away rather than ten; never below five.
  """
  @spec step_reps(pos_integer(), :up | :down) :: pos_integer()
  def step_reps(reps, :up) when reps >= @big_rep_steps_from, do: reps + 2 * @rep_step
  def step_reps(reps, :up), do: reps + @rep_step

  def step_reps(reps, :down) when reps > @big_rep_steps_from,
    do: max(reps - 2 * @rep_step, @big_rep_steps_from)

  def step_reps(reps, :down), do: max(reps - @rep_step, @rep_step)

  @doc """
  What a set may be limited to, for `reps` in all: steps of five below the total, then no limit
  (`nil`).
  """
  @spec set_sizes(pos_integer()) :: [pos_integer() | nil]
  def set_sizes(reps) when reps > @rep_step,
    do: Enum.to_list(@rep_step..(reps - 1)//@rep_step) ++ [nil]

  def set_sizes(_reps), do: [nil]

  @doc "The set size to start from: the step nearest a tenth of `reps`, or no limit when none."
  @spec default_set_size(pos_integer()) :: pos_integer() | nil
  def default_set_size(reps) do
    case set_sizes(reps) |> Enum.reject(&is_nil/1) do
      [] -> nil
      sizes -> Enum.min_by(sizes, &abs(&1 - reps / 10))
    end
  end

  @doc "The limit one step up (looser) or down (tighter) the list, staying at its ends."
  @spec step_set_size(pos_integer() | nil, :up | :down, pos_integer()) :: pos_integer() | nil
  def step_set_size(current, direction, reps) do
    options = set_sizes(reps)
    index = Enum.find_index(options, &(&1 == current)) || length(options) - 1

    Enum.at(
      options,
      max(min(index + if(direction == :up, do: 1, else: -1), length(options) - 1), 0)
    )
  end

  @doc """
  The movement pace, in seconds per rep, to start from: the middle of the reference range
  for the type, or less when the reps would leave under a sixth of the time for recovery.
  """
  @spec default_pace(atom(), pos_integer(), pos_integer()) :: float()
  def default_pace(burpee_type, reps, duration_sec) do
    {fastest, slowest} = WorkoutGuidance.default_active_seconds_range(burpee_type)
    fits = duration_sec * @work_share / reps
    round_to(min((fastest + slowest) / 2, fits), @pace_step) |> max(min_pace(burpee_type))
  end

  @doc """
  The fastest pace, in seconds per rep: the graduated level's count in 20 minutes (325
  six-count, 150 Navy SEAL), rounded up to a tenth so it is never faster.
  """
  @spec min_pace(atom()) :: float()
  def min_pace(burpee_type),
    do: Float.ceil(1_200 / Levels.threshold(:graduated, burpee_type), 1)

  @doc "The pace one step up or down, never faster than `min_pace/1`."
  @spec step_pace(number(), :up | :down, atom()) :: float()
  def step_pace(pace, :up, _burpee_type), do: round_to(pace + @pace_step, @pace_step)

  def step_pace(pace, :down, burpee_type),
    do: max(round_to(pace - @pace_step, @pace_step), min_pace(burpee_type))

  @doc """
  What `reps` at `pace` come to in `duration_sec`: whole seconds spent moving and left to
  recover, or `nil` when the movement alone would not fit.
  """
  @spec budget(pos_integer(), number(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def budget(reps, pace, duration_sec) do
    moving = round(reps * pace)
    if moving <= duration_sec, do: {moving, duration_sec - moving}, else: nil
  end

  @doc "The most reps `duration_sec` holds at `pace`, since movement alone must fit."
  @spec max_reps(number(), pos_integer()) :: pos_integer()
  def max_reps(pace, duration_sec), do: max(trunc(duration_sec / pace), 1)

  defp max_minutes(nil), do: @week_max_min
  defp max_minutes(remaining_sec), do: max(div(remaining_sec, 60), 1)

  # No recent session: the next level, which is also what the planner may reach for.
  defp landmark_rate(scope, burpee_type) do
    current = Levels.current_level(BurpeeTrainer.Workouts.list_sessions(scope))
    Levels.threshold(Levels.next(current) || current, burpee_type)
  end

  defp scale(rate, duration_sec) when duration_sec > @standard_min * 60,
    do: rate * duration_sec / 1_200 * @long_session_factor

  defp scale(rate, duration_sec), do: rate * duration_sec / 1_200

  defp snap(value, step), do: max(round(value / step) * step, step)
  defp round_to(value, step), do: Float.round(round(value / step) * step * 1.0, 1)
end
