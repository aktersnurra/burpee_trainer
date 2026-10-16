defmodule BurpeeTrainer.Coach.WorkoutConfiguration do
  @moduledoc "Local active-work arithmetic for the New form, not a workout scheduler."

  @spec budget(pos_integer(), number() | nil, pos_integer()) ::
          {:ok, map() | :unknown_pace} | {:error, atom()}
  def budget(_reps, nil, _duration), do: {:ok, :unknown_pace}

  def budget(reps, pace, duration)
      when is_integer(reps) and reps > 0 and is_number(pace) and pace > 0 and is_integer(duration) and
             duration > 0 do
    work = reps * round(pace * 1_000_000)
    recovery = duration * 1_000_000 - work

    if recovery >= 0,
      do: {:ok, %{work_us: work, recovery_us: recovery}},
      else: {:error, :work_exceeds_duration}
  end

  def budget(_, _, _), do: {:error, :invalid_budget}
end
