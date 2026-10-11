defmodule BurpeeTrainer.Coach.Rationale do
  @moduledoc """
  The planner's reason for a workout, shown to the athlete on Home. Tools refuse anything
  else with an error the model can act on, so nothing unfit for the athlete is stored.
  """

  alias BurpeeTrainer.Coach.Voice

  @max_length 280

  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @spec validate(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        {:error, "rationale must be one plain sentence for the athlete"}

      String.length(trimmed) > @max_length ->
        {:error, "rationale must be at most #{@max_length} characters"}

      id = Voice.internal_id(trimmed) ->
        {:error, "rationale must not contain internal ids such as #{id}"}

      true ->
        {:ok, trimmed}
    end
  end

  def validate(_text), do: {:error, "rationale must be a string"}
end
