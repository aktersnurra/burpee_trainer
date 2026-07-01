defmodule BurpeeTrainer.PlanSolver.Execution do
  @moduledoc """
  Canonical executable prescription emitted by `PlanSolver`.

  This is the source of truth for generated work: ordered set and rest events
  with concrete timing. Persisted blocks/steps and UI timeline rows are derived
  representations and must round-trip back to the same totals.
  """

  defmodule SetEvent do
    @moduledoc "One executable set in the prescription timeline."
    @enforce_keys [
      :kind,
      :index,
      :burpee_count,
      :sec_per_rep,
      :sec_per_burpee,
      :starts_at_sec,
      :duration_sec
    ]
    defstruct @enforce_keys
  end

  defmodule RestEvent do
    @moduledoc "One explicit rest in the prescription timeline."
    @enforce_keys [:kind, :index, :rest_sec, :starts_at_sec, :source]
    defstruct @enforce_keys
  end

  alias BurpeeTrainer.PlanSolver.{Prescription, Recovery}

  @type event :: SetEvent.t() | RestEvent.t()
  @type t :: [event()]

  @spec build(Prescription.t()) :: t()
  def build(%Prescription{pacing_style: :unbroken} = prescription) do
    recoveries_by_set = Enum.group_by(prescription.recoveries, & &1.after_set)

    {_elapsed, events} =
      prescription.set_pattern
      |> Enum.with_index(1)
      |> Enum.reduce({0.0, []}, fn {reps, set_index}, {elapsed, events} ->
        set_duration = reps * prescription.sec_per_rep

        set = %SetEvent{
          kind: :set,
          index: set_index,
          burpee_count: reps,
          sec_per_rep: prescription.sec_per_rep,
          sec_per_burpee: prescription.sec_per_rep,
          starts_at_sec: elapsed,
          duration_sec: set_duration
        }

        elapsed = elapsed + set_duration
        events = [set | events]

        recoveries = Map.get(recoveries_by_set, set_index, [])

        Enum.reduce(recoveries, {elapsed, events}, fn
          %Recovery{total_sec: total_sec} = recovery, {elapsed, events} when total_sec > 0 ->
            rest = %RestEvent{
              kind: :rest,
              index: length(events) + 1,
              rest_sec: total_sec,
              starts_at_sec: elapsed,
              source: recovery.source
            }

            {elapsed + total_sec, [rest | events]}

          _recovery, acc ->
            acc
        end)
      end)

    Enum.reverse(events)
  end

  def build(%Prescription{pacing_style: :even} = prescription) do
    set_pattern =
      case prescription.set_pattern do
        pattern when is_list(pattern) and pattern != [] -> pattern
        _other -> [prescription.burpee_count]
      end

    cadence_sec =
      prescription.cadence_sec || prescription.target_duration_sec / prescription.burpee_count

    set_cadences =
      case prescription.set_cadences do
        cadences when is_list(cadences) and length(cadences) == length(set_pattern) ->
          cadences

        _other ->
          List.duplicate(cadence_sec, length(set_pattern))
      end

    recoveries_by_set = Enum.group_by(prescription.recoveries, & &1.after_set)

    {_elapsed, events} =
      set_pattern
      |> Enum.zip(set_cadences)
      |> Enum.with_index(1)
      |> Enum.reduce({0.0, []}, fn {{reps, set_cadence_sec}, set_index}, {elapsed, events} ->
        duration_sec = reps * set_cadence_sec

        event = %SetEvent{
          kind: :set,
          index: set_index,
          burpee_count: reps,
          sec_per_rep: set_cadence_sec,
          sec_per_burpee: prescription.sec_per_rep,
          starts_at_sec: elapsed,
          duration_sec: duration_sec
        }

        elapsed = elapsed + duration_sec
        events = [event | events]

        recoveries = Map.get(recoveries_by_set, set_index, [])

        Enum.reduce(recoveries, {elapsed, events}, fn
          %Recovery{total_sec: total_sec} = recovery, {elapsed, events} when total_sec > 0 ->
            rest = %RestEvent{
              kind: :rest,
              index: length(events) + 1,
              rest_sec: total_sec,
              starts_at_sec: elapsed,
              source: recovery.source
            }

            {elapsed + total_sec, [rest | events]}

          _recovery, acc ->
            acc
        end)
      end)

    Enum.reverse(events)
  end

  @spec build([pos_integer()], [number()], [map()], number(), number()) :: t()
  def build(set_pattern, rest_pattern, reservations, sec_per_rep, sec_per_burpee) do
    reservations_by_slot = Map.new(reservations || [], &{&1.slot, &1})

    {_elapsed, _reps_done, events} =
      set_pattern
      |> Enum.with_index(1)
      |> Enum.reduce({0.0, 0, []}, fn {reps, set_index}, {elapsed, reps_done, events} ->
        set_duration = reps * sec_per_rep

        set = %SetEvent{
          kind: :set,
          index: set_index,
          burpee_count: reps,
          sec_per_rep: sec_per_rep,
          sec_per_burpee: sec_per_burpee,
          starts_at_sec: elapsed,
          duration_sec: set_duration
        }

        elapsed = elapsed + set_duration
        reps_done = reps_done + reps
        events = [set | events]

        {elapsed, events} =
          case Map.get(reservations_by_slot, reps_done) do
            %{rest_sec: rest_sec} = reservation ->
              rest = %RestEvent{
                kind: :rest,
                index: length(events) + 1,
                rest_sec: rest_sec,
                starts_at_sec: elapsed,
                source: {:additional, reservation.target_min}
              }

              {elapsed + rest_sec, [rest | events]}

            nil ->
              {elapsed, events}
          end

        auto_rest = Enum.at(rest_pattern, set_index - 1, 0)

        {elapsed, events} =
          if auto_rest > 0 do
            rest = %RestEvent{
              kind: :rest,
              index: length(events) + 1,
              rest_sec: auto_rest,
              starts_at_sec: elapsed,
              source: :auto
            }

            {elapsed + auto_rest, [rest | events]}
          else
            {elapsed, events}
          end

        {elapsed, reps_done, events}
      end)

    Enum.reverse(events)
  end

  @spec burpee_count(t()) :: non_neg_integer()
  def burpee_count(events) do
    events
    |> Enum.filter(&match?(%SetEvent{}, &1))
    |> Enum.reduce(0, fn event, total -> total + event.burpee_count end)
  end

  @spec duration_sec(t()) :: float()
  def duration_sec([]), do: 0.0

  def duration_sec(events) do
    Enum.reduce(events, 0.0, fn
      %SetEvent{} = event, _total -> event.starts_at_sec + event.duration_sec
      %RestEvent{} = event, _total -> event.starts_at_sec + event.rest_sec
    end)
  end
end
