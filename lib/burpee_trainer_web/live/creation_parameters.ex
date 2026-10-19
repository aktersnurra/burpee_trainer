defmodule BurpeeTrainerWeb.CreationParameters do
  @moduledoc "The creation surface's duration and burpee-type text: parsing and labels."

  def duration_seconds(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{1,4}):([0-5]\d)\z/, value) do
      [_, minutes, seconds] ->
        total = String.to_integer(minutes) * 60 + String.to_integer(seconds)
        if total in 1..86_400, do: {:ok, total}, else: :error

      _ ->
        :error
    end
  end

  def duration_seconds(_), do: :error

  def duration_label(seconds) do
    minutes = div(round(seconds), 60)
    remainder = rem(round(seconds), 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{minutes}:#{remainder}"
  end

  def type_label("six_count"), do: "Six-count"
  def type_label("navy_seal"), do: "Navy SEAL"
end
