defmodule BurpeeTrainer.PlanCompiler.CanonicalJson do
  @moduledoc """
  The one JSON encoding that content hashes are taken over: object keys as strings in
  sorted order, no whitespace. Changing it changes every stored hash.
  """

  @spec encode(term()) :: String.t()
  def encode(value) when is_map(value) do
    body =
      value
      |> Enum.map(fn {key, nested_value} -> {to_string(key), nested_value} end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> encode(nested_value)
      end)

    "{" <> body <> "}"
  end

  def encode(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode/1) <> "]"
  end

  def encode(value), do: Jason.encode!(value)
end
