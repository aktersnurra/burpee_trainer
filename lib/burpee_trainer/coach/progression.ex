defmodule BurpeeTrainer.Coach.Progression do
  @moduledoc "Evidence-based rate decisions for automatic coaching; manual choices remain independent."
  alias BurpeeTrainer.Coach.AuthoritativeSession
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.SetBreakdown

  # Slack, the window left after each set, warns before the athlete falls behind: a last
  # set with under a quarter of its rest left, on a shrinking curve, is close to the
  # ceiling. Half the rest left in every set, shrinking by under a quarter of a rest over
  # the session, is headroom for a bigger step. A curve that, carried on, reaches zero
  # within the workout's own sets is close to the ceiling too.
  @running_out_share 0.25
  @headroom_share 0.5

  defstruct action: :establish,
            reason: :no_comparable_history,
            evidence_ids: [],
            baseline_reps_per_20: nil,
            previous_reps_per_20: nil,
            min_reps_per_20: 0,
            max_reps_per_20: nil

  @type t :: %__MODULE__{}

  @spec for_type(BurpeeTrainer.Accounts.Scope.t(), atom()) :: t()
  def for_type(scope, type),
    do: decide(Workouts.list_sessions(scope, type), type, DateTime.utc_now())

  @spec decide([map()], atom(), DateTime.t()) :: t()
  def decide(sessions, type, now) do
    since = DateTime.add(now, -56, :day)

    recent =
      sessions
      |> Enum.filter(&comparable?(&1, type, since, now))
      |> Enum.sort_by(&{DateTime.to_unix(&1.completed_at, :microsecond), &1.id}, :desc)
      |> Enum.take(2)

    case recent do
      [] -> %__MODULE__{}
      [latest | rest] -> decision(latest, List.first(rest), recent)
    end
  end

  @spec allows?(t(), pos_integer(), pos_integer()) :: boolean()
  def allows?(%__MODULE__{max_reps_per_20: nil}, _reps, _duration), do: true

  def allows?(decision, reps, duration) do
    window = max(duration, 1200)

    reps * 1200 >= decision.min_reps_per_20 * window and
      reps * 1200 <= decision.max_reps_per_20 * window
  end

  @spec explanation(t()) :: String.t()
  def explanation(%__MODULE__{action: :establish}),
    do: "Find a steady starting pace; there is no comparable recent session yet."

  def explanation(%__MODULE__{action: :progress} = decision),
    do:
      "Two successful sessions support a small step: #{decision.min_reps_per_20}–#{decision.max_reps_per_20} reps per 20 minutes."

  def explanation(%__MODULE__{action: :ease} = decision),
    do:
      "Ease off after the last session: at most #{decision.max_reps_per_20} reps per 20 minutes."

  def explanation(%__MODULE__{} = decision),
    do: "Repeat around #{decision.max_reps_per_20} reps per 20 minutes before increasing."

  defp comparable?(session, type, since, now) do
    AuthoritativeSession.authoritative?(session) and session.burpee_type == type and
      session.tags != "warmup" and measured?(session) and long_enough?(session) and
      AuthoritativeSession.within_window?(session.completed_at, since, now)
  end

  defp measured?(session),
    do:
      is_integer(session.burpee_count_actual) and
        session.burpee_count_actual >= 0 and is_integer(session.duration_sec_actual) and
        session.duration_sec_actual > 0

  defp long_enough?(session),
    do: session.duration_sec_actual >= 1080 or (session.duration_sec_planned || 0) >= 1080

  defp decision(latest, previous, recent) do
    baseline = rate(latest)
    {action, reason, minimum, maximum} = prescription(latest, previous, baseline)

    %__MODULE__{
      action: action,
      reason: reason,
      evidence_ids: Enum.map(recent, & &1.id),
      baseline_reps_per_20: baseline,
      previous_reps_per_20: previous && rate(previous),
      min_reps_per_20: minimum,
      max_reps_per_20: maximum
    }
  end

  defp prescription(latest, previous, baseline) do
    slack = slack(latest)

    cond do
      late_slip?(latest) ->
        repeat(planned_rate(latest), :late_fatigue)

      latest.kept_up == false or missed_target?(latest) ->
        {:ease, :incomplete_or_early_fatigue, 1, max(1, div(baseline * 90, 100))}

      slack_running_out?(slack) ->
        repeat(max(1, baseline), :slack_running_out)

      repeated_success?(latest, previous, baseline) and headroom?(slack) ->
        {:progress, :repeated_success_with_headroom, baseline + 1, baseline + 8}

      repeated_success?(latest, previous, baseline) ->
        {:progress, :repeated_success, baseline + 1, baseline + 5}

      true ->
        repeat(max(1, baseline), :more_evidence_needed)
    end
  end

  defp repeated_success?(latest, previous, baseline),
    do:
      baseline >= 10 and successful?(latest) and successful?(previous) and
        baseline == rate(previous) and
        DateTime.diff(latest.completed_at, previous.completed_at) >= 86_400

  defp repeat(rate, reason), do: {:repeat, reason, max(1, div(rate * 95, 100)), rate}

  defp slack_running_out?(slack) do
    case slack do
      %{"trend_sec_per_set" => trend, "last_sec" => last, "rest_sec" => rest} ->
        (trend < 0 and last < rest * @running_out_share) or
          (is_integer(slack["runs_out_at_set"]) and
             slack["runs_out_at_set"] <= slack["sets_planned"])

      nil ->
        false
    end
  end

  # How much the window shrank is read from the first and last measured sets themselves,
  # not the trend times the sets measured: measured sets can skip set numbers.
  defp headroom?(slack) do
    case slack do
      %{"min_sec" => min, "rest_sec" => rest, "first_sec" => first, "last_sec" => last} ->
        min >= rest * @headroom_share and first - last < rest * @running_out_share

      nil ->
        false
    end
  end

  # Only when the camera caught the opening, so a shrinking curve is the athlete, not it.
  defp slack(%{kept_up: true} = session),
    do:
      SetBreakdown.for_session(
        Map.get(session, :cadence_ms),
        Map.get(session, :program_snapshot)
      ).window_slack

  defp slack(_session), do: nil

  defp late_slip?(%{kept_up: false, slip_at_sec: slip, duration_sec_planned: planned})
       when is_number(slip) and is_integer(planned) and planned > 0,
       do: slip * 3 >= planned * 2

  defp late_slip?(_), do: false

  defp missed_target?(%{burpee_count_planned: planned, burpee_count_actual: actual})
       when is_integer(planned) and planned > 0, do: actual < planned

  defp missed_target?(_), do: false

  defp successful?(
         %{mood: mood, kept_up: kept_up, context_low_energy: false, context_heat_affected: false} =
           session
       )
       when mood in [0, 1] and kept_up != false do
    is_integer(session.burpee_count_planned) and session.burpee_count_planned > 0 and
      is_integer(session.duration_sec_planned) and session.duration_sec_planned > 0 and
      not missed_target?(session) and session.duration_sec_actual <= session.duration_sec_planned
  end

  defp successful?(_), do: false

  # An unfinished prescription must not look faster because it ended early.
  defp rate(session),
    do:
      div(
        session.burpee_count_actual * 1200,
        max(1200, max(session.duration_sec_actual, session.duration_sec_planned || 0))
      )

  defp planned_rate(session),
    do: div(session.burpee_count_planned * 1200, max(1200, session.duration_sec_planned))
end
