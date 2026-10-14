defmodule BurpeeTrainer.Coach.Suggestions do
  @moduledoc """
  What the athlete might say next, as the coach predicts it: at most three short, distinct
  phrases, each one tap on the Coach screen. Whatever the model sends is cleaned here.
  """

  @max 3
  @max_length 60

  @spec clean(term()) :: [String.t()]
  def clean(items) when is_list(items) do
    items
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != "" and String.valid?(&1) and String.length(&1) <= @max_length))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(@max)
  end

  def clean(_items), do: []

  @doc "The JSON schema a model reply uses for them."
  @spec schema() :: map()
  def schema,
    do: %{
      "type" => "array",
      "maxItems" => @max,
      "items" => %{"type" => "string", "maxLength" => @max_length}
    }
end
