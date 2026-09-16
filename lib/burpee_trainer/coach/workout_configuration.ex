defmodule BurpeeTrainer.Coach.WorkoutConfiguration do
  @moduledoc "Bounded set/rest notation and local active-work arithmetic, not a workout scheduler."
  @max_sets 5_000
  @max_text_bytes 4_000

  @spec parse_sets(String.t() | nil) :: {:ok, [pos_integer()]} | {:error, atom()}
  def parse_sets(nil), do: {:ok, []}

  def parse_sets(text) when is_binary(text) and byte_size(text) <= @max_text_bytes do
    text = String.trim(text) |> String.replace("×", "x")
    if text == "", do: {:ok, []}, else: consume_sets(text, [])
  end

  def parse_sets(_), do: {:error, :invalid_set_configuration}

  defp consume_sets(text, acc) do
    case Regex.run(~r/\A\s*(\d+)\s*[xX]\s*(\d+|\(\s*\d+(?:\s*,\s*\d+)*\s*\))\s*(.*)\z/s, text) do
      [_, repeat, group, tail] ->
        count = String.to_integer(repeat)

        reps =
          group
          |> String.trim("(")
          |> String.trim(")")
          |> String.split(",")
          |> Enum.map(&(String.trim(&1) |> String.to_integer()))

        size = count * length(reps)

        if count > 0 and size + length(acc) <= @max_sets and Enum.all?(reps, &(&1 in 1..100_000)) do
          expanded = acc ++ List.flatten(List.duplicate(reps, count))

          case tail do
            "" -> {:ok, expanded}
            "," <> rest when rest != "" -> consume_sets(rest, expanded)
            _ -> {:error, :invalid_set_configuration}
          end
        else
          {:error, :invalid_set_configuration}
        end

      _ ->
        {:error, :invalid_set_configuration}
    end
  end

  @spec parse_rests(String.t() | nil) :: {:ok, [map()]} | {:error, atom()}
  def parse_rests(nil), do: {:ok, []}

  def parse_rests(text) when is_binary(text) and byte_size(text) <= @max_text_bytes do
    lines = String.split(text, ~r/[\n;,]/, trim: true)

    if length(lines) <= 64 do
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
        match = Regex.run(~r/\A\s*(\d+)\s*s\s+at\s+(\d{1,4}:[0-5]\d)\s*\z/i, line)

        match =
          case match do
            [_, seconds, time] ->
              [time, seconds]

            _ ->
              case Regex.run(~r/\A\s*(\d{1,4}:[0-5]\d)\s*\/\s*(\d+)\s*s?\s*\z/i, line) do
                [_, time, seconds] -> [time, seconds]
                _ -> nil
              end
          end

        case match do
          [time, seconds] ->
            [minutes, remainder] = String.split(time, ":")
            start = String.to_integer(minutes) * 60 + String.to_integer(remainder)
            duration = String.to_integer(seconds)

            if duration in 1..86_400 and start <= 86_400,
              do: {:cont, {:ok, acc ++ [%{"start_sec" => start, "duration_sec" => duration}]}},
              else: {:halt, {:error, :invalid_rests}}

          _ ->
            {:halt, {:error, :invalid_rests}}
        end
      end)
    else
      {:error, :invalid_rests}
    end
  end

  def parse_rests(_), do: {:error, :invalid_rests}

  @spec budget(pos_integer(), number() | nil, pos_integer()) ::
          {:ok, map() | :unknown_pace} | {:error, atom()}
  def budget(_reps, nil, _duration), do: {:ok, :unknown_pace}

  def budget(reps, pace, duration)
      when is_integer(reps) and reps > 0 and is_number(pace) and pace > 0 and is_integer(duration) and
             duration > 0 do
    work = reps * round(pace * 1_000_000)
    recovery = duration * 1_000_000 - work

    if recovery >= 0,
      do: {:ok, %{work_us: work, recovery_us: recovery}},
      else: {:error, :work_exceeds_duration}
  end

  def budget(_, _, _), do: {:error, :invalid_budget}
end
