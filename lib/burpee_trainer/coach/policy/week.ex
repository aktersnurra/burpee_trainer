defmodule BurpeeTrainer.Coach.Policy.Week do
  @moduledoc """
  One local training week.

  The sign-up week is pro-rated to 20 minutes per remaining day (capped at the full target)
  and has no catch-up days; every other week has the full target and weekend catch-up.
  Callers read the fields; nothing else asks whether a user is new.
  """

  @enforce_keys [:start, :target_sec, :catch_up_days]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          start: Date.t(),
          target_sec: pos_integer(),
          catch_up_days: [1..7]
        }

  @full_target_sec 4_800
  @daily_sec 1_200
  @weekend [6, 7]

  @doc "The week starting on `week_start` for a user who signed up on `sign_up_date`."
  @spec new(Date.t(), Date.t()) :: t()
  def new(%Date{} = sign_up_date, %Date{} = week_start),
    do: week(Date.beginning_of_week(sign_up_date) == week_start, sign_up_date, week_start)

  defp week(true = _sign_up_week, sign_up_date, week_start) do
    days_left = Date.diff(Date.end_of_week(sign_up_date), sign_up_date) + 1

    %__MODULE__{
      start: week_start,
      target_sec: min(@daily_sec * days_left, @full_target_sec),
      catch_up_days: []
    }
  end

  defp week(false, _sign_up_date, week_start),
    do: %__MODULE__{start: week_start, target_sec: @full_target_sec, catch_up_days: @weekend}
end
