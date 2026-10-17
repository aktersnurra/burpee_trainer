defmodule BurpeeTrainerWeb.HomeDayBoundary do
  @moduledoc "Pure scheduling arithmetic for the next user-local day boundary."

  alias BurpeeTrainer.UserTime

  @spec delay_ms(%{:timezone => String.t(), optional(atom()) => any()}, DateTime.t()) ::
          {:ok, pos_integer()} | {:error, :invalid_timezone}
  def delay_ms(user, now) do
    with {:ok, context} <- UserTime.context(user, now),
         {:ok, midnight} <-
           UserTime.resolve_local(Date.add(context.date, 1), ~T[00:00:00], context.timezone) do
      {:ok, max(DateTime.diff(midnight, now, :millisecond), 1)}
    end
  end
end
