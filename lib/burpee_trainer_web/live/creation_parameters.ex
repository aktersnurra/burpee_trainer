defmodule BurpeeTrainerWeb.CreationParameters do
  @moduledoc "The creation surface's bounded natural-language request, not a second workout definition."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:burpee_type, :string, default: "six_count")
    field(:duration, :string, default: "20:00")
    field(:reps, :integer, default: 120)
    field(:pacing, :string, default: "unbroken")
    field(:distribution, :string, default: "front_loaded")
    field(:note, :string, default: "")
  end

  def changeset(parameters, attrs) do
    parameters
    |> cast(attrs, [:burpee_type, :duration, :reps, :pacing, :distribution, :note])
    |> validate_required([:burpee_type, :duration, :reps, :pacing, :distribution])
    |> validate_inclusion(:burpee_type, ~w(six_count navy_seal))
    |> validate_inclusion(:pacing, ~w(unbroken even))
    |> validate_inclusion(:distribution, ~w(balanced front_loaded))
    |> validate_number(:reps, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_length(:note, max: 300)
    |> validate_change(:duration, fn :duration, value ->
      case duration_seconds(value) do
        {:ok, _} -> []
        :error -> [duration: "Enter a duration from 0:01 to 1440:00"]
      end
    end)
  end

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

  def request(%__MODULE__{} = parameters) do
    {:ok, seconds} = duration_seconds(parameters.duration)
    note = String.trim(parameters.note || "")

    "#{type_label(parameters.burpee_type)}; duration: #{seconds} seconds; total reps: #{parameters.reps}; " <>
      "pacing: #{pacing_label(parameters.pacing)}; distribution: #{distribution_label(parameters.distribution)}." <>
      if(note == "", do: "", else: "\nNote: #{note}")
  end

  def type_label("six_count"), do: "6-count"
  def type_label("navy_seal"), do: "Navy SEAL"
  def pacing_label("unbroken"), do: "Unbroken"
  def pacing_label("even"), do: "Even"
  def distribution_label("balanced"), do: "Balanced"
  def distribution_label("front_loaded"), do: "Front-loaded"
end
