defmodule BurpeeTrainer.PlanWizard.Reservation do
  @moduledoc """
  Reservation solver: places each `additional_rest` (a `{rest_sec, target_min}`
  pair from `%PlanInput{}`) onto a specific inter-rep slot in a `%SlotModel{}`.

  ## Model

  A reservation requests "rest of `R` seconds approximately `T` minutes into
  the workout". We pick the slot whose projected wall-clock time is closest
  to `T × 60`, subject to a `±30s` tolerance (see
  `BurpeeTrainer.PlanWizard.Errors.placement_tolerance_sec/0`).

  Projected slot time uses the rest distribution that the continuous solver
  *would* produce if no reservations existed:

      slot_time(i) = i × sec_per_burpee + Σ_{k≤i} expected_rest(k)

  where `expected_rest(k) = rest_budget × weight(k) / Σ(weights)`.

  This matches the legacy semantics:

    * `:even` — every weight is 1.0, so `expected_rest(k)` is constant and
      `slot_time(i) = i × shaved_cadence`. Same number the legacy
      `find_even_splits/3` used.
    * `:unbroken` — weights are 1.0 only at set boundaries; non-boundary
      slots have `expected_rest = 0`. Slot times at set boundaries match
      the legacy `build_set_boundaries/1` accumulation.

  ## Placement style

  Reservations are processed in `target_min` order. For `:even`, each
  reservation must land on a slot strictly after the previous reservation's
  slot (matching legacy `prev_split + 1` behaviour) and before the final
  rep (so at least one rep remains in the trailing segment). For
  `:unbroken`, reservations are placed independently on the nearest
  set-boundary slot (matching legacy independent placement).

  Conflicts where two reservations want the same slot are surfaced via the
  per-style placement constraints; for `:even` the `prev_split + 1`
  bumping handles the common case automatically.
  """

  alias BurpeeTrainer.PlanWizard.{Errors, SlotModel}

  @doc """
  Place all reservations in `model.additional_rests_input` onto specific
  slots, returning the model with `:reservations` filled in.

  Returns `{:ok, model}` or `{:error, [message]}`.
  """
  @spec place(SlotModel.t()) :: {:ok, SlotModel.t()} | {:error, [String.t()]}
  def place(%SlotModel{additional_rests_input: []} = model) do
    {:ok, %{model | reservations: []}}
  end

  def place(%SlotModel{} = model) do
    sorted = Enum.sort_by(model.additional_rests_input, & &1.target_min)
    slot_times = projected_slot_times(model)

    case do_place(model.style, sorted, slot_times, model) do
      {:ok, reservations} -> {:ok, %{model | reservations: Enum.reverse(reservations)}}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Style-specific placement
  # ---------------------------------------------------------------------------

  defp do_place(:even, sorted, slot_times, model) do
    total_reps = model.total_reps

    Enum.reduce_while(sorted, {:ok, [], 0}, fn rest, {:ok, acc, prev_slot} ->
      target_sec = rest.target_min * 60.0

      # Legacy: ideal = round(target_sec / cadence); bump to prev_slot+1; cap at total_reps - 1.
      # Under projected slot times (which equal i × shaved_cadence for :even), the
      # nearest slot to target_sec is round(target_sec / cadence). We replicate the
      # legacy bumping/capping behaviour explicitly.
      cadence = even_cadence(slot_times)
      ideal = if cadence > 0, do: round(target_sec / cadence), else: prev_slot + 1
      slot = ideal |> max(prev_slot + 1) |> min(total_reps - 1)
      actual_time = Enum.at(slot_times, slot - 1)

      if within_tolerance?(actual_time, target_sec) do
        {:cont, {:ok, [reservation(slot, rest) | acc], slot}}
      else
        {:halt, out_of_tolerance_error(:even, rest.target_min, actual_time, target_sec)}
      end
    end)
    |> case do
      {:ok, acc, _} -> {:ok, acc}
      {:error, _} = err -> err
    end
  end

  defp do_place(:unbroken, sorted, slot_times, model) do
    boundary_slots = boundary_slots(model)

    cond do
      boundary_slots == [] ->
        {:halt_first_rest, sorted}
        |> only_one_set_error()

      true ->
        Enum.reduce_while(sorted, {:ok, []}, fn rest, {:ok, acc} ->
          target_sec = rest.target_min * 60.0

          {nearest_slot, nearest_time} =
            boundary_slots
            |> Enum.map(fn s -> {s, Enum.at(slot_times, s - 1)} end)
            |> Enum.min_by(fn {_s, t} -> abs(t - target_sec) end)

          if within_tolerance?(nearest_time, target_sec) do
            {:cont, {:ok, [reservation(nearest_slot, rest) | acc]}}
          else
            {:halt, out_of_tolerance_error(:unbroken, rest.target_min, nearest_time, target_sec)}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, acc}
          {:error, _} = err -> err
        end
    end
  end

  defp only_one_set_error({:halt_first_rest, [%{target_min: t} | _]}) do
    {:error, [Errors.cannot_place_rest_only_one_set(t)]}
  end

  # ---------------------------------------------------------------------------
  # Slot-time projection
  # ---------------------------------------------------------------------------

  # Cumulative slot wall-clock times: time at slot i = end of rep i + slot rest k≤i.
  # We project as if no reservations exist — the budget distributes across all
  # weighted slots. This matches legacy: :even uses shaved cadence, :unbroken
  # uses set-boundary accumulation.
  defp projected_slot_times(%SlotModel{} = model) do
    weight_sum = Enum.sum(model.weights)
    budget = SlotModel.rest_budget(model)
    s = model.sec_per_burpee

    expected_rests =
      if weight_sum > 0 do
        Enum.map(model.weights, fn w -> budget * w / weight_sum end)
      else
        List.duplicate(0.0, length(model.weights))
      end

    {times, _} =
      expected_rests
      |> Enum.with_index(1)
      |> Enum.map_reduce(0.0, fn {rest, i}, acc ->
        # Time at slot i = i reps of work + Σ(rest at slots 1..i)
        t = i * s + acc + rest
        {t, acc + rest}
      end)

    times
  end

  # For :even, all weights are 1.0 → cadence = sec_per_burpee + (budget / weight_count).
  # Equivalent to slot_times[0]; we read from there for consistency.
  defp even_cadence(slot_times) do
    case slot_times do
      [first | _] -> first
      [] -> 0.0
    end
  end

  defp boundary_slots(%SlotModel{weights: weights}) do
    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {w, i} when w > 0.0 -> [i]
      _ -> []
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp reservation(slot, %{rest_sec: r, target_min: t}) do
    %{slot: slot, rest_sec: r, target_min: t}
  end

  defp within_tolerance?(actual_sec, target_sec) do
    abs(actual_sec - target_sec) <= Errors.placement_tolerance_sec()
  end

  defp out_of_tolerance_error(style, target_min, actual_sec, target_sec) do
    nearest_min = Float.round(actual_sec / 60, 1)
    diff = round(abs(actual_sec - target_sec))

    msg =
      case style do
        :even ->
          Errors.cannot_place_rest_out_of_tolerance_even(target_min, nearest_min, diff)

        :unbroken ->
          Errors.cannot_place_rest_out_of_tolerance_unbroken(target_min, nearest_min, diff)
      end

    {:error, [msg]}
  end
end
