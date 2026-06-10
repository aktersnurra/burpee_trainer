defmodule BurpeeTrainer.PlanNotation do
  @moduledoc """
  Compact human notation for workout structures.

  `[a,b]` is one block of sets with `a` then `b` reps; `N×[a,b]` repeats
  that block `N` times. Examples:

      "20×[8]"            — twenty sets of 8
      "14×[8] 4×[7]"      — fourteen sets of 8, then four sets of 7
      "5×[8] 5×[7,6]"     — five blocks of one 8-rep set, then five
                            blocks of a 7-rep set followed by a 6-rep set
  """

  @type work_segment :: %{kind: :work, repeat: pos_integer(), pattern: [pos_integer()]}
  @type rest_segment :: %{kind: :rest, rest_sec: pos_integer()}
  @type segment :: work_segment() | rest_segment()

  @doc """
  Formats a flat set pattern (e.g. `[8, 8, 7]`) by grouping consecutive
  equal set sizes into repeated single-set blocks.
  """
  @spec from_pattern([pos_integer()]) :: String.t()
  def from_pattern(set_pattern) when is_list(set_pattern) do
    set_pattern
    |> Enum.chunk_by(& &1)
    |> Enum.map(fn [reps | _] = group -> work_text(length(group), [reps]) end)
    |> Enum.join(" ")
  end

  @doc "Formats a list of segments, including rest segments."
  @spec from_segments([segment()]) :: String.t()
  def from_segments(segments) when is_list(segments) do
    segments
    |> Enum.map(fn
      %{kind: :work, repeat: repeat, pattern: pattern} -> work_text(repeat, pattern)
      %{kind: :rest, rest_sec: rest_sec} -> "(rest #{rest_sec}s)"
    end)
    |> Enum.join(" ")
  end

  defp work_text(1, pattern), do: "[#{Enum.join(pattern, ",")}]"
  defp work_text(repeat, pattern), do: "#{repeat}×[#{Enum.join(pattern, ",")}]"
end
