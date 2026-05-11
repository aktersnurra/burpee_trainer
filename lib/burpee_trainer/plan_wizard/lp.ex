defmodule BurpeeTrainer.PlanWizard.Lp do
  @moduledoc """
  Builds an `%Lp.Problem{}` from a `%SlotModel{}`. Pure function — no I/O.

  Reservations contribute binary `x_<k>_<i>` assignment variables and the
  linearization machinery (`y_<k>_<i>`, big-M rest-amount linkage,
  placement-error rows).
  """

  alias BurpeeTrainer.PlanWizard.{Errors, SlotModel}
  alias BurpeeTrainer.PlanWizard.Lp.Problem

  @epsilon 1.0e-3

  @spec build(SlotModel.t()) :: Problem.t()
  def build(%SlotModel{total_reps: n}) when n <= 1 do
    # Degenerate: 0 or 1 reps means no inter-rep slots and no rest decisions
    # to make. Return an empty feasible problem; the solver will produce an
    # empty `r` vector and Apply will collapse to a one-set workout.
    %Problem{
      objective_sense: :minimize,
      objective_terms: [],
      variables: [],
      constraints: []
    }
  end

  def build(%SlotModel{} = model) do
    n = model.total_reps
    slot_count = n - 1
    ideal = SlotModel.ideal_rests(model)
    total_rest = model.target_duration_sec - model.total_reps * model.sec_per_burpee
    big_m = max(model.target_duration_sec * 1.0, 1.0)

    reservations =
      model.additional_rests_input
      |> Enum.sort_by(& &1.target_min)
      |> Enum.with_index(1)
      |> Enum.map(fn {r, k} ->
        %{k: k, rest_sec: r.rest_sec * 1.0, target_sec: r.target_min * 60.0}
      end)

    allowed = Enum.map(reservations, &allowed_slots(&1, model))

    r_vars = for i <- 1..slot_count, do: continuous("r_#{i}")
    e_vars = for i <- 1..slot_count, do: continuous("e_#{i}")

    x_vars =
      for {res, slots} <- Enum.zip(reservations, allowed),
          i <- slots,
          do: binary("x_#{res.k}_#{i}")

    y_vars =
      for {res, slots} <- Enum.zip(reservations, allowed),
          i <- slots,
          do: continuous("y_#{res.k}_#{i}")

    d_vars = for res <- reservations, do: continuous("d_#{res.k}")

    constraints =
      [total_duration_row(slot_count, total_rest)] ++
        zero_weight_rows(model) ++
        deviation_rows(slot_count, ideal) ++
        assignment_rows(reservations, allowed) ++
        one_per_slot_rows(slot_count, reservations, allowed) ++
        ordering_rows(model, reservations, allowed) ++
        rest_linkage_rows(reservations, allowed, big_m) ++
        y_linearization_rows(reservations, allowed, big_m, slot_count, model.sec_per_burpee) ++
        placement_error_rows(reservations, allowed) ++
        tolerance_rows(reservations)

    objective_terms =
      Enum.map(reservations, fn r -> {"d_#{r.k}", 1.0} end) ++
        for(i <- 1..slot_count, do: {"e_#{i}", @epsilon})

    %Problem{
      objective_sense: :minimize,
      objective_terms: objective_terms,
      variables: r_vars ++ e_vars ++ x_vars ++ y_vars ++ d_vars,
      constraints: constraints
    }
  end

  defp allowed_slots(%{target_sec: target}, %SlotModel{} = model) do
    projected = projected_slot_times(model)
    tolerance = Errors.placement_tolerance_sec() * 1.0

    projected
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {t, i} ->
      if abs(t - target) <= tolerance and slot_eligible?(model, i),
        do: [i],
        else: []
    end)
  end

  defp slot_eligible?(%SlotModel{style: :unbroken, weights: weights}, i),
    do: Enum.at(weights, i - 1) > 0.0

  defp slot_eligible?(%SlotModel{}, _i), do: true

  # For `:unbroken`, projection picks among set-boundary slots — flat is geometrically correct
  # and avoids the ideal-rest concentration artifact.
  defp projected_slot_times(%SlotModel{
         style: :unbroken,
         total_reps: n,
         target_duration_sec: total_sec
       }) do
    for i <- 1..(n - 1), do: i * total_sec / n
  end

  # For `:even`, cumulative-ideal-on-reservation-free-model respects fatigue bias while not
  # double-subtracting reservation time from the rest budget.
  defp projected_slot_times(%SlotModel{} = model) do
    s = model.sec_per_burpee
    ideal = SlotModel.ideal_rests(%{model | additional_rests_input: []})

    {times, _} =
      ideal
      |> Enum.with_index(1)
      |> Enum.map_reduce(0.0, fn {rest, i}, acc ->
        t = i * s + acc + rest
        {t, acc + rest}
      end)

    times
  end

  defp continuous(name),
    do: %{name: name, type: :continuous, lower: 0.0, upper: :pos_inf}

  defp binary(name),
    do: %{name: name, type: :binary, lower: 0.0, upper: 1.0}

  defp total_duration_row(slot_count, budget) do
    %{
      name: "TOTAL_DUR",
      terms: for(i <- 1..slot_count, do: {"r_#{i}", 1.0}),
      comparator: :eq,
      rhs: budget * 1.0
    }
  end

  defp zero_weight_rows(%SlotModel{weights: weights}) do
    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {w, i} ->
      if w == 0.0,
        do: [%{name: "ZERO_SLOT_#{i}", terms: [{"r_#{i}", 1.0}], comparator: :eq, rhs: 0.0}],
        else: []
    end)
  end

  defp deviation_rows(slot_count, ideal) do
    Enum.flat_map(1..slot_count, fn i ->
      ideal_i = Enum.at(ideal, i - 1)

      [
        %{
          name: "DEV_POS_#{i}",
          terms: [{"r_#{i}", -1.0}, {"e_#{i}", 1.0}],
          comparator: :geq,
          rhs: -ideal_i
        },
        %{
          name: "DEV_NEG_#{i}",
          terms: [{"r_#{i}", 1.0}, {"e_#{i}", 1.0}],
          comparator: :geq,
          rhs: ideal_i
        }
      ]
    end)
  end

  defp assignment_rows(reservations, allowed) do
    Enum.zip(reservations, allowed)
    |> Enum.map(fn {res, slots} ->
      %{
        name: "ASSIGN_#{res.k}",
        terms: Enum.map(slots, fn i -> {"x_#{res.k}_#{i}", 1.0} end),
        comparator: :eq,
        rhs: 1.0
      }
    end)
  end

  defp one_per_slot_rows(slot_count, reservations, allowed) do
    pairs = Enum.zip(reservations, allowed)

    Enum.flat_map(1..slot_count, fn i ->
      uses =
        for {res, slots} <- pairs, i in slots, do: {"x_#{res.k}_#{i}", 1.0}

      if length(uses) >= 2 do
        [%{name: "ONE_PER_SLOT_#{i}", terms: uses, comparator: :leq, rhs: 1.0}]
      else
        []
      end
    end)
  end

  defp ordering_rows(%SlotModel{style: :even}, reservations, allowed) do
    pairs = Enum.zip(reservations, allowed)

    pairs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{k1_res, k1_slots}, {k2_res, k2_slots}] ->
      terms =
        Enum.map(k2_slots, fn i -> {"x_#{k2_res.k}_#{i}", i * 1.0} end) ++
          Enum.map(k1_slots, fn i -> {"x_#{k1_res.k}_#{i}", -i * 1.0} end)

      %{
        name: "ORDER_#{k1_res.k}",
        terms: terms,
        comparator: :geq,
        rhs: 1.0
      }
    end)
  end

  defp ordering_rows(_model, _reservations, _allowed), do: []

  defp rest_linkage_rows(reservations, allowed, big_m) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      Enum.flat_map(slots, fn i ->
        [
          %{
            name: "RLINK_LO_#{res.k}_#{i}",
            terms: [{"r_#{i}", 1.0}, {"x_#{res.k}_#{i}", -big_m}],
            comparator: :geq,
            rhs: res.rest_sec - big_m
          },
          %{
            name: "RLINK_HI_#{res.k}_#{i}",
            terms: [{"r_#{i}", 1.0}, {"x_#{res.k}_#{i}", big_m}],
            comparator: :leq,
            rhs: res.rest_sec + big_m
          }
        ]
      end)
    end)
  end

  defp y_linearization_rows(reservations, allowed, big_m, _slot_count, sec_per_burpee) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      Enum.flat_map(slots, fn i ->
        slot_end_terms = for j <- 1..i, do: {"r_#{j}", -1.0}

        [
          %{
            name: "YBND_X_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0}, {"x_#{res.k}_#{i}", -big_m}],
            comparator: :leq,
            rhs: 0.0
          },
          %{
            name: "YBND_SE_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0} | slot_end_terms],
            comparator: :leq,
            rhs: i * sec_per_burpee * 1.0
          },
          %{
            name: "YBND_LO_#{res.k}_#{i}",
            terms: [
              {"y_#{res.k}_#{i}", 1.0},
              {"x_#{res.k}_#{i}", -big_m} | slot_end_terms
            ],
            comparator: :geq,
            rhs: i * sec_per_burpee * 1.0 - big_m
          }
        ]
      end)
    end)
  end

  defp placement_error_rows(reservations, allowed) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      y_terms_neg = Enum.map(slots, fn i -> {"y_#{res.k}_#{i}", -1.0} end)
      y_terms_pos = Enum.map(slots, fn i -> {"y_#{res.k}_#{i}", 1.0} end)

      [
        %{
          name: "PERR_POS_#{res.k}",
          terms: [{"d_#{res.k}", 1.0} | y_terms_neg],
          comparator: :geq,
          rhs: -res.target_sec
        },
        %{
          name: "PERR_NEG_#{res.k}",
          terms: [{"d_#{res.k}", 1.0} | y_terms_pos],
          comparator: :geq,
          rhs: res.target_sec
        }
      ]
    end)
  end

  defp tolerance_rows(reservations) do
    Enum.map(reservations, fn res ->
      %{
        name: "TOL_#{res.k}",
        terms: [{"d_#{res.k}", 1.0}],
        comparator: :leq,
        rhs: Errors.placement_tolerance_sec() * 1.0
      }
    end)
  end
end
