defmodule BurpeeTrainerWeb.Params do
  @moduledoc """
  Safe conversions for values that arrive from the client.

  `String.to_integer/1` and `String.to_existing_atom/1` both raise on
  unexpected input. Raising inside `handle_event/3` kills the LiveView
  process, so a crafted event would take the page down. These helpers return
  `:error` instead, letting callers ignore the event.
  """

  @doc """
  Parses a non-negative integer index, returning `:error` for anything else.
  """
  @spec index(term()) :: {:ok, non_neg_integer()} | :error
  def index(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def index(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  def index(_value), do: :error

  @doc """
  Converts a value to an atom only when it appears in `allowed`.

  `allowed` holds the permitted values as strings, so the atoms are known to
  exist at conversion time.
  """
  @spec known_atom(term(), [String.t()]) :: {:ok, atom()} | :error
  def known_atom(value, allowed) when is_binary(value) do
    if value in allowed, do: {:ok, String.to_existing_atom(value)}, else: :error
  end

  def known_atom(_value, _allowed), do: :error
end
