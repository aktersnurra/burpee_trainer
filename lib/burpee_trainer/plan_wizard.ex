defmodule BurpeeTrainer.PlanWizard do
  @moduledoc """
  Public entry point for converting a `%PlanInput{}` into a `%WorkoutPlan{}`.

  Implementation lives in `BurpeeTrainer.PlanWizard.Solver` (constraint
  pipeline producing a `%SlotModel{}`) and `BurpeeTrainer.PlanWizard.Apply`
  (collapsing the slot model into Blocks/Sets). This module is the thin
  wrapper that resolves defaults, handles the degenerate one-set
  `:unbroken` case, and exposes the legacy `validate_pace/2` and
  `default_reps_per_set/1` helpers used by the LiveView.

  Pacing styles:
    :even     — uniform cadence throughout. With additional rests, cadence
                is uniformly shaved so the total time is unchanged. Each
                rest is injected at the nearest rep boundary (within 30s).
    :unbroken — user-specified reps_per_set. Reps within a set are done
                continuously; remaining time is distributed as
                end_of_set_rest between sets. Additional rests are injected
                at the nearest set boundary (within 30s).

  Physical pace floors (graduation landmark, max reps in 20 min):
    six_count:  sec_per_burpee >= 3.70s
    navy_seal:  sec_per_burpee >= 8.00s
  """

  alias BurpeeTrainer.PlanWizard.{Apply, Errors, PlanInput, SlotModel, Solver, Styles}
  alias BurpeeTrainer.PlanWizard.Constraints.PaceFloor
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @sec_per_burpee_floor %{
    six_count: Float.ceil(1200 / 325, 2),
    navy_seal: 1200 / 150
  }

  @default_reps_per_set %{six_count: 10, navy_seal: 5}

  @doc """
  Validate pace against the physical floor for the given burpee type.
  Returns `:ok` or `{:error, :pace_too_fast, floor_value}`.
  """
  @spec validate_pace(atom, float) :: :ok | {:error, :pace_too_fast, float}
  def validate_pace(burpee_type, sec_per_burpee) do
    case Map.get(@sec_per_burpee_floor, burpee_type) do
      nil -> :ok
      floor when sec_per_burpee >= floor -> :ok
      floor -> {:error, :pace_too_fast, floor}
    end
  end

  @doc "Default reps-per-set for a given burpee type (:six_count or :navy_seal)."
  def default_reps_per_set(burpee_type), do: Map.get(@default_reps_per_set, burpee_type, 10)

  @doc """
  Generate a `%WorkoutPlan{}` from a `%PlanInput{}`.
  Returns `{:ok, plan}` or `{:error, [reason_string]}`.
  """
  @spec generate(PlanInput.t()) :: {:ok, WorkoutPlan.t()} | {:error, [String.t()]}
  def generate(%PlanInput{} = input) do
    with {:ok, reps_per_set} <- resolve_reps_per_set(input) do
      run_pipeline(input, reps_per_set)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_reps_per_set(%PlanInput{pacing_style: :even}), do: {:ok, nil}

  defp resolve_reps_per_set(%PlanInput{pacing_style: :unbroken} = input) do
    reps_per_set = input.reps_per_set || default_reps_per_set(input.burpee_type)

    if is_integer(reps_per_set) and reps_per_set > 0 do
      {:ok, reps_per_set}
    else
      {:error, [Errors.reps_per_set_invalid()]}
    end
  end

  # Degenerate `:unbroken` case: reps_per_set ≥ total_reps. The legacy
  # implementation produced a single set with no inter-set rest and total
  # duration < target. The solver pipeline would reject this (TotalDuration
  # constraint), so we short-circuit and apply directly. Additional rests
  # in this configuration cannot be placed — there are no set boundaries —
  # so we surface the legacy "only one set generated" error.
  defp run_pipeline(%PlanInput{pacing_style: :unbroken} = input, reps_per_set)
       when is_integer(reps_per_set) do
    cond do
      reps_per_set >= input.burpee_count_target and input.additional_rests in [nil, []] ->
        with :ok <- PaceFloor.check_input(input), do: apply_one_set_unbroken(input)

      reps_per_set >= input.burpee_count_target ->
        with :ok <- PaceFloor.check_input(input) do
          [%{target_min: t} | _] = input.additional_rests
          {:error, [Errors.cannot_place_rest_only_one_set(t)]}
        end

      true ->
        solve_and_apply(input, reps_per_set)
    end
  end

  defp run_pipeline(%PlanInput{pacing_style: :even} = input, _reps_per_set) do
    solve_and_apply(input, nil)
  end

  defp solve_and_apply(input, reps_per_set) do
    with {:ok, model} <- Solver.solve(input, reps_per_set),
         {:ok, plan} <- Apply.to_workout_plan(model, input) do
      {:ok, plan}
    end
  end

  # Build a one-set :unbroken plan via Apply directly. We construct a
  # minimal SlotModel — Apply only reads structural fields (style,
  # total_reps, reps_per_set, reservations) for `:unbroken`, and our
  # `set_size = min(reps_per_set, total_reps)` reduces to `total_reps`.
  defp apply_one_set_unbroken(input) do
    model = %SlotModel{
      total_reps: input.burpee_count_target,
      sec_per_burpee: input.sec_per_burpee,
      target_duration_sec: input.target_duration_min * 60,
      style: :unbroken,
      reps_per_set: input.burpee_count_target,
      weights:
        Styles.weight_vector(:unbroken, input.burpee_count_target, input.burpee_count_target),
      additional_rests_input: [],
      reservations: [],
      slot_rests: List.duplicate(0.0, max(input.burpee_count_target - 1, 0))
    }

    Apply.to_workout_plan(model, input)
  end
end
