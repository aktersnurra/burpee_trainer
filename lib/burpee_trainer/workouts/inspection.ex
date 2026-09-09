defmodule BurpeeTrainer.Workouts.Inspection do
  @moduledoc """
  Lossless display grouping of canonical, compiler-validated workout plans.

  Units retain both definition and program values: compiler rounding must not
  make distinct prescriptions equal. Leading and trailing recovery stay explicit.
  """

  @spec rows(BurpeeTrainer.Workouts.WorkoutPlan.t()) :: [map()]
  def rows(plan) do
    paired =
      Enum.zip(plan.definition_json["events"], plan.program_json["events"])
      |> Enum.with_index()
      |> Enum.map(fn {{definition, program}, index} ->
        %{definition: definition, program: program, index: index}
      end)

    last_work = paired |> Enum.filter(&(&1.program["kind"] == "work")) |> List.last()
    {body, trailing} = Enum.split(paired, last_work.index + 1)
    {leading, body} = Enum.split_while(body, &(&1.program["kind"] == "rest"))
    prefix = "home-row-#{plan.id}-#{DateTime.to_unix(plan.updated_at, :microsecond)}"

    Enum.map(leading, &row(prefix, [unit([&1])], 1, false)) ++
      group(prefix, units(body), []) ++
      Enum.map(trailing, &row(prefix, [unit([&1])], 1, true))
  end

  @spec flatten([map()]) :: [map()]
  def flatten(rows), do: Enum.flat_map(rows, & &1.events)

  defp units([]), do: []

  defp units([work | rest]) do
    {recovery, remaining} = Enum.split_while(rest, &(&1.program["kind"] == "rest"))
    [unit([work | recovery]) | units(remaining)]
  end

  defp unit(events), do: %{paired: events, exact: Enum.map(events, &{&1.definition, &1.program})}

  defp group(_prefix, [], acc), do: Enum.reverse(acc)

  defp group(prefix, units, acc) do
    {width, count} = repeated_prefix(units) || {1, 1}
    {consumed, rest} = Enum.split(units, width * count)
    group(prefix, rest, [row(prefix, consumed, count, false) | acc])
  end

  defp repeated_prefix(units) do
    maximum = div(length(units), 2)

    if maximum > 0 do
      Enum.find_value(1..maximum, fn width ->
        exact = units |> Enum.take(width) |> Enum.map(& &1.exact)

        count =
          units
          |> Enum.chunk_every(width, width, :discard)
          |> Enum.take_while(&(Enum.map(&1, fn u -> u.exact end) == exact))
          |> length()

        if count >= 2, do: {width, count}
      end)
    end
  end

  defp row(prefix, units, count, trailing?) do
    paired = Enum.flat_map(units, & &1.paired)
    first = hd(paired)

    kind =
      cond do
        count > 1 -> :repeat
        first.program["kind"] == "rest" -> :recovery
        true -> :set
      end

    %{
      id: "#{prefix}-#{first.index}",
      kind: kind,
      count: count,
      units: units,
      events: Enum.map(paired, & &1.program),
      trailing?: trailing?
    }
  end
end
