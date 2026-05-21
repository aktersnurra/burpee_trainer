defmodule BurpeeTrainer.PlanSolver.Lp do
  @moduledoc """
  Builds a `%Milp.Problem{}` for the session planner.

  Extends the slot-distribution LP with `p` (sec_per_burpee) as a free
  variable. The total-duration constraint and deviation rows both reference
  `p`; the objective minimizes -α*p (prefer slower, more sustainable pace)
  plus a small deviation regularizer.
  """

  alias BurpeeTrainer.Milp.Problem
  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.Input

  @alpha 0.6
  @epsilon 1.0e-3
  @placement_tolerance_sec 30.0
  @max_pace 30.0

  @spec build(Input.t(), pos_integer | nil) :: Problem.t()
  def build(%Input{} = input, reps_per_set) do
    n = input.burpee_count_target
    ceiling = PlanSolver.sustainable_ceiling(input.burpee_type, input.level)
    target_sec = input.target_duration_min * 60.0
    add_rest_total = Enum.reduce(input.additional_rests || [], 0.0, &(&1.rest_sec + &2))
    budget_const = target_sec - add_rest_total

    weights = weight_vector(input.pacing_style, n, reps_per_set)
    active_count = Enum.count(weights, &(&1 > 0.0))

    slot_count = max(n - 1, 0)
    big_m = max(target_sec * 1.0, 1.0)

    reservations = build_reservations(input)

    allowed =
      Enum.map(
        reservations,
        &allowed_slots(&1, n, weights, input.pacing_style, ceiling, target_sec)
      )

    p_var = %{name: "p", type: :continuous, lower: ceiling, upper: @max_pace}
    r_vars = for i <- 1..slot_count//1, do: continuous("r_#{i}")
    e_vars = for i <- 1..slot_count//1, do: continuous("e_#{i}")

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
      total_duration_row(slot_count, n, budget_const) ++
        zero_weight_rows(weights) ++
        deviation_rows(weights, active_count, n, budget_const) ++
        assignment_rows(reservations, allowed) ++
        one_per_slot_rows(slot_count, reservations, allowed) ++
        ordering_rows(input.pacing_style, reservations, allowed) ++
        rest_linkage_rows(reservations, allowed, big_m) ++
        y_linearization_rows(reservations, allowed, big_m) ++
        placement_error_rows(reservations, allowed) ++
        tolerance_rows(reservations)

    objective_terms =
      [{"p", -@alpha}] ++
        Enum.map(reservations, fn r -> {"d_#{r.k}", 1.0} end) ++
        for(i <- 1..slot_count//1, do: {"e_#{i}", @epsilon})

    %Problem{
      objective_sense: :minimize,
      objective_terms: objective_terms,
      variables: [p_var] ++ r_vars ++ e_vars ++ x_vars ++ y_vars ++ d_vars,
      constraints: constraints
    }
  end

  defp weight_vector(:even, n, _reps_per_set) when n > 1, do: List.duplicate(1.0, n - 1)
  defp weight_vector(:even, _n, _), do: []

  defp weight_vector(:unbroken, n, reps_per_set) when is_integer(reps_per_set) and n > 1 do
    for i <- 1..(n - 1) do
      if rem(i, reps_per_set) == 0, do: 1.0, else: 0.0
    end
  end

  defp weight_vector(:unbroken, n, _) when n > 1, do: List.duplicate(0.0, n - 1)
  defp weight_vector(_, _, _), do: []

  defp build_reservations(%Input{additional_rests: rests}) do
    rests
    |> Enum.sort_by(& &1.target_min)
    |> Enum.with_index(1)
    |> Enum.map(fn {r, k} ->
      %{k: k, rest_sec: r.rest_sec * 1.0, target_sec: r.target_min * 60.0}
    end)
  end

  defp allowed_slots(%{target_sec: target_s}, n, weights, style, ceiling, total_sec) do
    projected = projected_slot_times(n, weights, style, ceiling, total_sec)

    projected
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {t, i} ->
      if abs(t - target_s) <= @placement_tolerance_sec and slot_eligible?(weights, style, i),
        do: [i],
        else: []
    end)
  end

  defp slot_eligible?(weights, :unbroken, i), do: Enum.at(weights, i - 1, 0.0) > 0.0
  defp slot_eligible?(_weights, _style, _i), do: true

  defp projected_slot_times(n, _weights, :unbroken, _ceiling, total_sec) do
    for i <- 1..(n - 1)//1, do: i * total_sec / n
  end

  defp projected_slot_times(n, _weights, :even, ceiling, total_sec) do
    rest_per_slot = max(total_sec - n * ceiling, 0.0) / max(n - 1, 1)
    for i <- 1..(n - 1)//1, do: i * ceiling + i * rest_per_slot
  end

  defp continuous(name), do: %{name: name, type: :continuous, lower: 0.0, upper: :pos_inf}
  defp binary(name), do: %{name: name, type: :binary, lower: 0.0, upper: 1.0}

  defp total_duration_row(0, _n, _budget_const), do: []

  defp total_duration_row(slot_count, n, budget_const) do
    r_terms = for i <- 1..slot_count//1, do: {"r_#{i}", 1.0}
    [%{name: "TOTAL_DUR", terms: [{"p", n * 1.0} | r_terms], comparator: :eq, rhs: budget_const}]
  end

  defp zero_weight_rows(weights) do
    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {w, i} when w == 0.0 ->
        [%{name: "ZERO_SLOT_#{i}", terms: [{"r_#{i}", 1.0}], comparator: :eq, rhs: 0.0}]

      _ ->
        []
    end)
  end

  # ideal_i = A - B*p  where A = budget_const/active_count, B = N/active_count
  # e_i ≥  r_i - ideal_i  →  -r_i + e_i - B*p ≥ -A
  # e_i ≥ -r_i + ideal_i  →   r_i + e_i + B*p ≥  A
  defp deviation_rows(weights, active_count, n, budget_const) when active_count > 0 do
    a = budget_const / active_count
    b = n * 1.0 / active_count

    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {w, _i} when w == 0.0 ->
        []

      {_w, i} ->
        [
          %{
            name: "DEV_POS_#{i}",
            terms: [{"r_#{i}", -1.0}, {"e_#{i}", 1.0}, {"p", -b}],
            comparator: :geq,
            rhs: -a
          },
          %{
            name: "DEV_NEG_#{i}",
            terms: [{"r_#{i}", 1.0}, {"e_#{i}", 1.0}, {"p", b}],
            comparator: :geq,
            rhs: a
          }
        ]
    end)
  end

  defp deviation_rows(_weights, 0, _n, _budget_const), do: []

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

    Enum.flat_map(1..slot_count//1, fn i ->
      uses = for {res, slots} <- pairs, i in slots, do: {"x_#{res.k}_#{i}", 1.0}

      if length(uses) >= 2,
        do: [%{name: "ONE_PER_SLOT_#{i}", terms: uses, comparator: :leq, rhs: 1.0}],
        else: []
    end)
  end

  defp ordering_rows(:even, reservations, allowed) do
    Enum.zip(reservations, allowed)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{k1_res, k1_slots}, {k2_res, k2_slots}] ->
      terms =
        Enum.map(k2_slots, fn i -> {"x_#{k2_res.k}_#{i}", i * 1.0} end) ++
          Enum.map(k1_slots, fn i -> {"x_#{k1_res.k}_#{i}", -i * 1.0} end)

      %{name: "ORDER_#{k1_res.k}", terms: terms, comparator: :geq, rhs: 1.0}
    end)
  end

  defp ordering_rows(_style, _reservations, _allowed), do: []

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

  # slot_end_time[i] = i*p + Σ_{j≤i} r_j
  # YBND_SE: y - i*p - Σ r_j ≤ 0  (p moved to LHS with coefficient -i)
  # YBND_LO: y - i*p - Σ r_j - M*x ≥ -M
  defp y_linearization_rows(reservations, allowed, big_m) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      Enum.flat_map(slots, fn i ->
        r_terms = for j <- 1..i//1, do: {"r_#{j}", -1.0}

        [
          %{
            name: "YBND_X_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0}, {"x_#{res.k}_#{i}", -big_m}],
            comparator: :leq,
            rhs: 0.0
          },
          %{
            name: "YBND_SE_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0}, {"p", -i * 1.0} | r_terms],
            comparator: :leq,
            rhs: 0.0
          },
          %{
            name: "YBND_LO_#{res.k}_#{i}",
            terms: [
              {"y_#{res.k}_#{i}", 1.0},
              {"p", -i * 1.0},
              {"x_#{res.k}_#{i}", -big_m} | r_terms
            ],
            comparator: :geq,
            rhs: -big_m
          }
        ]
      end)
    end)
  end

  defp placement_error_rows(reservations, allowed) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      y_neg = Enum.map(slots, fn i -> {"y_#{res.k}_#{i}", -1.0} end)
      y_pos = Enum.map(slots, fn i -> {"y_#{res.k}_#{i}", 1.0} end)

      [
        %{
          name: "PERR_POS_#{res.k}",
          terms: [{"d_#{res.k}", 1.0} | y_neg],
          comparator: :geq,
          rhs: -res.target_sec
        },
        %{
          name: "PERR_NEG_#{res.k}",
          terms: [{"d_#{res.k}", 1.0} | y_pos],
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
        rhs: @placement_tolerance_sec
      }
    end)
  end
end
