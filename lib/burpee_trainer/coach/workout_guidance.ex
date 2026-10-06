defmodule BurpeeTrainer.Coach.WorkoutGuidance do
  @moduledoc "Shared, level-aware training guidance for structured workout proposals."

  alias BurpeeTrainer.{Levels, UserTime, Workouts}

  # General movement references, not measured individual capacity:
  # https://busydadtraining.com/6-count-burpee/
  # https://busydadtraining.com/navy-seal-burpee/
  @default_active_seconds_range %{six_count: {4.0, 5.0}, navy_seal: {7.0, 9.0}}

  @spec default_active_seconds_range(:six_count | :navy_seal) :: {float(), float()}
  def default_active_seconds_range(burpee_type),
    do: Map.fetch!(@default_active_seconds_range, burpee_type)

  @training_rules """
  You design the structure of one burpee workout as a layout. You choose phases, sets, reps
  per set, movement timing and relative rest weights; the application computes every rest
  duration exactly, so never reason about cumulative time or exact rest seconds.

  Phases: fixed pauses requested by the user split the workout into phases. Return exactly
  one phase per segment between fixed pauses, in order. Each phase contains its sets in order
  and one positive weight per gap between consecutive sets. Equal weights give even rests;
  larger weights give longer rests at that gap. Rest time saved for extended pauses comes out
  of ordinary rests automatically.

  Sets and timing: the sum of reps over all sets equals target_reps. sec_per_burpee is active
  movement time per rep; sec_per_rep is start-to-start time per rep and is >= sec_per_burpee
  (equal for unbroken style). If the request has requested_pace_sec, every set's
  sec_per_burpee equals it. Use at most three decimals. Movement must leave time for rests in
  every phase that has more than one set. Preserve explicit ordered set_reps exactly.

  Recovery: when recovery is required, use at least two sets so rests exist; when forbidden,
  use one set and no fixed pauses. Approximate block lengths mean work plus its rest, not work
  alone.

  Levels are achieved landmarks, not targets. Use comparable previous workouts, accounting for
  burpee type and duration; do not extrapolate a short session's density to a long one. A
  six-count burpee is roughly 4-5 s of active movement and a Navy Seal roughly 8 s; these are
  defaults when no pace is requested, not measurements of this user. Never infer medical
  conditions. If the targets cannot be met, say so in the rationale instead of inventing a plan.
  """

  @spec system_prompt(BurpeeTrainer.Accounts.Scope.t()) :: String.t()
  def system_prompt(
        %BurpeeTrainer.Accounts.Scope{user: %BurpeeTrainer.Accounts.User{} = user} = scope
      ) do
    {:ok, context} = UserTime.context(user, DateTime.utc_now(:second))

    levels =
      Levels.all_levels()
      |> Enum.reverse()
      |> Enum.map(fn level ->
        %{
          level: level,
          six_count: Levels.threshold(level, :six_count),
          navy_seal: Levels.threshold(level, :navy_seal)
        }
      end)

    recent_results =
      scope
      |> Workouts.list_recent_training_sessions()
      |> Enum.filter(&(is_integer(&1.burpee_count_actual) and is_integer(&1.duration_sec_actual)))
      |> Enum.map(fn session ->
        %{
          burpee_type: session.burpee_type,
          actual_reps: session.burpee_count_actual,
          actual_duration_sec: session.duration_sec_actual,
          completed_on: DateTime.to_date(session.completed_at)
        }
      end)

    @training_rules <>
      "\nReturn only the layout JSON.\n" <>
      Jason.encode!(%{
        current_level:
          Levels.current_level(
            Workouts.list_sessions(scope),
            context.date
          ),
        level_landmarks: levels,
        recent_results: recent_results
      })
  end
end
