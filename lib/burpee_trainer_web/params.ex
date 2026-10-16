defmodule BurpeeTrainerWeb.Params do
  @moduledoc "Parsing of untrusted route and event parameters."

  @doc "A positive integer id from its decimal string; anything else is invalid."
  @spec positive_id(term()) :: {:ok, pos_integer()} | {:error, :invalid_id}
  def positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid_id}
    end
  end

  def positive_id(_forged), do: {:error, :invalid_id}
end
