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
  The reps to start from for `duration_sec`: the rate the athlete's recent sessions of this
  type support, within what the planner would allow, scaled to the duration and rounded to
  a step. With no history it is the next level's landmark.
  """
  @spec suggested_reps(Scope.t(), atom(), pos_integer()) :: pos_integer()
  def suggested_reps(%Scope{} = scope, burpee_type, duration_sec) do
    rate =
      case progression_rate(Progression.for_type(scope, burpee_type)) do
        nil -> landmark_rate(scope, burpee_type)
        rate -> capped(rate, RepCeiling.for_type(scope, burpee_type))
      end

    rate |> scale(duration_sec) |> snap(@rep_step)
  end

  @doc "The reps one step up or down, never below a step."
  @spec step_reps(pos_integer(), :up | :down) :: pos_integer()
  def step_reps(reps, :up), do: reps + @rep_step
  def step_reps(reps, :down), do: max(reps - @rep_step, @rep_step)

  @doc """
  What a set may be limited to, for `reps` in all: steps of five below the total, then no limit
  (`nil`), which is where it starts.
  """
  @spec set_sizes(pos_integer()) :: [pos_integer() | nil]
  def set_sizes(reps) when reps > @rep_step,
    do: Enum.to_list(@rep_step..(reps - 1)//@rep_step) ++ [nil]

  def set_sizes(_reps), do: [nil]

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
    round_to(min((fastest + slowest) / 2, fits), @pace_step) |> max(@pace_step)
  end

  @doc "The pace one step up or down, never below a step."
  @spec step_pace(number(), :up | :down) :: float()
  def step_pace(pace, :up), do: round_to(pace + @pace_step, @pace_step)
  def step_pace(pace, :down), do: max(round_to(pace - @pace_step, @pace_step), @pace_step)

  @doc "The most reps `duration_sec` holds at `pace`, since movement alone must fit."
  @spec max_reps(number(), pos_integer()) :: pos_integer()
  def max_reps(pace, duration_sec), do: max(trunc(duration_sec / pace), 1)

  defp max_minutes(nil), do: @week_max_min
  defp max_minutes(remaining_sec), do: max(div(remaining_sec, 60), 1)

  defp progression_rate(%Progression{
         action: :progress,
         min_reps_per_20: low,
         max_reps_per_20: high
       })
       when is_integer(high),
       do: div(low + high, 2)

  defp progression_rate(%Progression{max_reps_per_20: high}) when is_integer(high), do: high
  defp progression_rate(%Progression{}), do: nil

  defp capped(rate, {:ok, {:recent_best, cap}}), do: min(rate, cap)
  defp capped(rate, _ceiling), do: rate

  # No comparable session: their recent best, or with none the next level, which is also
  # what the planner may reach for.
  defp landmark_rate(scope, burpee_type) do
    case RepCeiling.for_type(scope, burpee_type) do
      # The ceiling is 10% above their best; the suggestion is the best itself.
      {:ok, {:recent_best, cap}} -> div(cap * 100, 110)
      _none -> Levels.threshold(next_level(scope), burpee_type)
    end
  end

  defp next_level(scope) do
    levels = Enum.reverse(Levels.all_levels())
    current = Levels.current_level(BurpeeTrainer.Workouts.list_sessions(scope))
    index = Enum.find_index(levels, &(&1 == current))
    Enum.at(levels, index + 1, current)
  end

  defp scale(rate, duration_sec) when duration_sec > @standard_min * 60,
    do: rate * duration_sec / 1_200 * @long_session_factor

  defp scale(rate, duration_sec), do: rate * duration_sec / 1_200

  defp snap(value, step), do: max(round(value / step) * step, step)
  defp round_to(value, step), do: Float.round(round(value / step) * step * 1.0, 1)
end
