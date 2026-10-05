defmodule BurpeeTrainer.Coach.WorkoutGuidance do
  @moduledoc "Shared, level-aware training guidance for structured workout proposals."

  alias BurpeeTrainer.{Levels, UserTime, Workouts}

  # General movement references, not measured individual capacity:
  # https://busydadtraining.com/6-count-burpee/
  # https://busydadtraining.com/navy-seal-burpee/
  # The site's "roughly 8 seconds" for Navy Seals gets a one-second tolerance so minor
  # variation does not spend a second provider call for an otherwise valid workout.
  @default_active_seconds_range %{six_count: {4.0, 5.0}, navy_seal: {7.0, 9.0}}

  @spec default_active_seconds_range(:six_count | :navy_seal) :: {float(), float()}
  def default_active_seconds_range(burpee_type),
    do: Map.fetch!(@default_active_seconds_range, burpee_type)

  @training_rules """
  The events array is the source of truth for the entire workout.
  In a phased response, concatenate each phase's work/rest pairs and last work set, followed
  by its mandatory rest field; that becomes the ordered events array. The phased schema has
  no literal events key. Construct ordered work and rest events before writing the rationale. Describe only events
  that actually exist in the array. A pause described only in the rationale is not a rest event.
  Unbroken means continuous reps within each set, not a rest-free workout. When recovery is
  requested, each work event is one set; place a positive rest event between consecutive work
  events. For a rest requested at a specific time, sum all preceding event durations;
  start its rest event at that exact elapsed second, with the requested duration. Do not shift
  a timed rest or leave the clock empty. Estimate work time from reps and movement pace, then
  allocate the remaining time to between-set rest events instead of slower reps or prose.
  By default, try to distribute available recovery evenly across between-set pauses.
  Compare total pauses, including cadence tails, rather than only explicit rest fields.
  Explicit recovery instructions take precedence: preserve requested uneven pauses,
  and keep mandatory pauses exact while spreading other recovery as evenly as feasible.
  Even distribution is a preference, not a hard constraint; never override requested
  reps, ordered sets, active pace, pause timing or total duration to achieve it.
  Compare ordinary pauses across the whole workout, not independently inside each phase;
  exclude the mandatory total pauses from that comparison. Timed anchors fix phase durations,
  not the number of sets or reps assigned to a phase. If those allocations are not constrained,
  jointly choose set counts and rep allocation across phases around a shared ordinary-rest baseline.
  Do not fill a phase with large ordinary pauses just because its work sets were made too long
  or too few. Explicit ordered set_reps remain hard constraints; do not regroup them for evenness.
  In recovery-allocation instructions, approximate minute-long sets/blocks mean work plus ordinary recovery,
  unless the user explicitly asks for work-only duration. For example, 8 reps at 5 seconds
  plus 20 seconds of ordinary recovery form a minute block; 12 reps plus 60 seconds of rest
  form a two-minute block, not a minute block. Keep the requested active movement pace unchanged.
  Start with roughly that work/recovery cycle, then fund mandatory pauses by shaving ordinary
  recovery, preferably beforehand. Rebalance unconstrained phase allocations before deciding
  ordinary pauses must be very different. Explain any unavoidable ordinary-rest differences
  or block-length compromises from the actual events, rather than claiming an untested impossibility.
  Report the actual compiled duration in the rationale, not an exact requested duration
  when the events only satisfy its timing tolerance.
  An extended rest is the TOTAL pause, not added recovery. Replacing a normal 25s pause
  with 60s requires only 35s more recovery. Preserve requested ordered set_reps exactly.
  Prefer borrowing preceding end-of-set recovery for Unbroken, or preceding between-rep
  gaps and set recovery for Even; borrow future recovery if necessary. Never shorten active
  movement, create negative recovery, or silently change reps or sets. A supplied active pace
  constrains sec_per_burpee, not Even start-to-start sec_per_rep. Unbroken sets require these
  two values to be equal. Count cadence tails as recovery: with this phased schema, use
  sec_per_rep equal to sec_per_burpee in the work immediately before a mandatory extended
  rest so its fixed rest field remains the whole pause. Do not concatenate rest fragments
  into a longer pause than requested. Preserve the ±10s duration/start tolerance and exact
  pause durations; the compiler's actual event durations are authoritative.
  Minute blocks, or two minutes if movement exceeds one minute, are level-1/2 defaults,
  not hard rules. Higher levels can use longer sets or shorter recovery.
  The sum of reps across every work event must equal target_reps; rest events contribute zero
  reps. When the user requests no rest, events must contain no rest events. Work and rest
  durations must sum exactly to target_duration_sec: non-terminal work uses reps * sec_per_rep;
  terminal work uses (reps - 1) * sec_per_rep + sec_per_burpee.
  Use at most three decimal places for generated second values. Check cumulative starts
  and the exact total at the compiler's millisecond precision before returning JSON.
  Balance fractional recovery by adjusting flexible pauses at millisecond precision,
  never a mandatory pause or active movement.

  Levels are achieved landmarks, not workout targets. A qualifying level result is completed
  within 20 minutes; the combined level requires both burpee types in the same ISO week.
  Do not prescribe the next level's rep threshold just because it is the next landmark.
  Use comparable previous workouts, accounting for burpee type and duration. A short session's
  density must not be extrapolated linearly to a long one. Pace means active movement time per rep.
  Cadence also includes transitions between reps; whole-session density includes rests and
  cannot establish movement pace on its own. Busy Dad Training describes a six-count burpee
  as roughly 4-5 seconds of active movement and a Navy Seal as roughly 8 seconds. These are
  general references, not measurements of this user or rigid speed limits. When recovery is
  requested and no active pace is specified, use these as the default movement-time range;
  respect any explicitly requested or measured pace. Levels guide set size and recovery, not
  movement-speed limits. Preserve an explicit rep target; do not silently lower it. When
  choosing a target yourself, balance feasible reps with fatigue and recovery. If requested
  targets conflict with feasible work and recovery, fail instead of inventing a plan.
  Never infer a medical condition or an unmeasured movement pace from prior results.
  """

  @spec system_prompt(BurpeeTrainer.Accounts.User.t(), :definition) :: String.t()
  def system_prompt(user, kind) when kind == :definition do
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
      user
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

    output_rule =
      "Return only one version-1 workout definition object matching the exact schema. " <>
        "Include at least one work event. If the user requests no rest, include no rest events."

    @training_rules <>
      "\n" <>
      output_rule <>
      "\n" <>
      Jason.encode!(%{
        current_level: Levels.current_level(Workouts.list_sessions(user), context.date),
        level_landmarks: levels,
        recent_results: recent_results
      })
  end
end
