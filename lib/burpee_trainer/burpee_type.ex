defmodule BurpeeTrainer.BurpeeType do
  @moduledoc """
  Safe parser for supported burpee types.
  """

  @type t :: :six_count | :navy_seal
  @type error :: {:invalid_burpee_type, term()}

  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(:six_count), do: {:ok, :six_count}
  def parse(:navy_seal), do: {:ok, :navy_seal}
  def parse("six_count"), do: {:ok, :six_count}
  def parse("navy_seal"), do: {:ok, :navy_seal}
  def parse(value), do: {:error, {:invalid_burpee_type, value}}
end
