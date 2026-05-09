defmodule BurpeeTrainer.PlanWizard.Constraints.PaceFloor do
  @moduledoc """
  Hard constraint: every slot's effective cadence (`sec_per_burpee +
  slot_rest`) must be at least `sec_per_burpee`. Equivalently, every
  `slot_rest` must be ≥ 0 — but this constraint is phrased in pace terms so
  the error message can name the original input the user controls
  (`sec_per_burpee` and `additional_rests`).

  Two checks happen at different pipeline stages:

    * `check_input/1` — before reservation/distribution. Catches the case
      where total work alone exceeds target, or work + additional rests
      forces shaved cadence below the burpee floor.
    * `check_distributed/1` — after the continuous solver fills
      `slot_rests`. Re-validates per-slot in case soft constraints push a
      slot below the floor (today the closed-form distribution can't, but
      the check is cheap insurance).
  """

  alias BurpeeTrainer.PlanWizard.{Errors, PlanInput, SlotModel}

  @sec_per_burpee_floor %{
    six_count: Float.ceil(1200 / 325, 2),
    navy_seal: 1200 / 150
  }

  @doc "Per-burpee-type minimum sec_per_burpee (graduation pace floor)."
  def burpee_type_floor(burpee_type), do: Map.get(@sec_per_burpee_floor, burpee_type)

  @spec check_input(PlanInput.t()) :: :ok | {:error, [String.t()]}
  def check_input(%PlanInput{} = input) do
    target_sec = input.target_duration_min * 60
    work_sec = input.burpee_count_target * input.sec_per_burpee
    total_add_rest = Enum.sum(for r <- input.additional_rests || [], do: r.rest_sec)

    cond do
      (floor = burpee_type_floor(input.burpee_type)) && input.sec_per_burpee < floor ->
        {:error, [Errors.pace_too_fast(input.sec_per_burpee, floor, input.burpee_type)]}

      work_sec > target_sec ->
        {:error, [Errors.work_exceeds_target(work_sec, target_sec)]}

      input.pacing_style == :even and total_add_rest > 0 ->
        base_cadence = target_sec / input.burpee_count_target
        shaved = base_cadence - total_add_rest / input.burpee_count_target

        if shaved < input.sec_per_burpee do
          max_rest =
            Float.round(
              (base_cadence - input.sec_per_burpee) * input.burpee_count_target,
              1
            )

          {:error,
           [Errors.rest_exceeds_pace_floor(total_add_rest, input.sec_per_burpee, max_rest)]}
        else
          :ok
        end

      input.pacing_style == :unbroken and work_sec + total_add_rest > target_sec ->
        {:error, [Errors.work_plus_rests_exceed_target(work_sec, total_add_rest, target_sec)]}

      true ->
        :ok
    end
  end

  @spec check_distributed(SlotModel.t()) :: :ok | {:error, [String.t()]}
  def check_distributed(%SlotModel{slot_rests: nil}), do: :ok

  def check_distributed(%SlotModel{slot_rests: rests}) do
    if Enum.any?(rests, &(&1 < -1.0e-9)) do
      {:error, ["pace floor violated: a slot received negative rest"]}
    else
      :ok
    end
  end
end
