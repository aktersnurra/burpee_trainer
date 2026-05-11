defmodule BurpeeTrainer.PlanWizard.Mps do
  @moduledoc """
  Serializes a `%Lp.Problem{}` to standard MPS format.

  Conventions:
    * Free objective row is named "COST".
    * Binary variables are wrapped in MARKER 'INTORG'/'INTEND' blocks.
    * Continuous variables ≥ 0 have lower bound 0 (implicit, but emitted
      for clarity).
  """

  alias BurpeeTrainer.PlanWizard.Lp.Problem

  @objective_row "COST"

  @spec serialize(Problem.t()) :: String.t()
  def serialize(%Problem{} = p) do
    IO.iodata_to_binary([
      "NAME          BURPEE_PLAN\n",
      "ROWS\n",
      rows_section(p),
      "COLUMNS\n",
      columns_section(p),
      "RHS\n",
      rhs_section(p),
      "BOUNDS\n",
      bounds_section(p),
      "ENDATA\n"
    ])
  end

  defp rows_section(p) do
    [
      " N  #{@objective_row}\n"
      | Enum.map(p.constraints, fn c -> " #{row_tag(c.comparator)}  #{c.name}\n" end)
    ]
  end

  defp row_tag(:eq), do: "E"
  defp row_tag(:leq), do: "L"
  defp row_tag(:geq), do: "G"

  defp columns_section(p) do
    by_var = group_terms_by_var(p)

    {iodata, prev_kind} =
      Enum.map_reduce(p.variables, :continuous, fn var, prev_kind ->
        entries = Map.get(by_var, var.name, [])
        lines = column_lines(var.name, entries)

        transitions =
          cond do
            prev_kind != :binary and var.type == :binary -> [intorg_marker()]
            prev_kind == :binary and var.type != :binary -> [intend_marker()]
            true -> []
          end

        {[transitions, lines], var.type}
      end)

    if prev_kind == :binary, do: [iodata, intend_marker()], else: iodata
  end

  defp intorg_marker, do: "    MARKER                 'MARKER'                 'INTORG'\n"
  defp intend_marker, do: "    MARKER                 'MARKER'                 'INTEND'\n"

  defp group_terms_by_var(p) do
    obj_entries = Enum.map(p.objective_terms, fn {name, c} -> {name, {@objective_row, c}} end)

    constraint_entries =
      Enum.flat_map(p.constraints, fn con ->
        Enum.map(con.terms, fn {name, c} -> {name, {con.name, c}} end)
      end)

    (obj_entries ++ constraint_entries)
    |> Enum.reduce(%{}, fn {var, pair}, acc ->
      Map.update(acc, var, [pair], &[pair | &1])
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  defp column_lines(_var_name, []), do: []

  defp column_lines(var_name, entries) do
    entries
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [{r1, c1}, {r2, c2}] ->
        "    #{var_name}  #{r1}  #{fmt(c1)}   #{r2}  #{fmt(c2)}\n"

      [{r1, c1}] ->
        "    #{var_name}  #{r1}  #{fmt(c1)}\n"
    end)
  end

  defp rhs_section(p) do
    p.constraints
    |> Enum.reject(fn c -> c.rhs == 0.0 end)
    |> Enum.map(fn c -> "    RHS  #{c.name}  #{fmt(c.rhs)}\n" end)
  end

  defp bounds_section(p) do
    Enum.flat_map(p.variables, fn
      %{type: :binary, name: name} ->
        [" BV BND  #{name}\n"]

      %{type: :continuous, lower: lower, upper: :pos_inf} = _v when lower == 0.0 ->
        []

      %{type: :continuous, name: name, lower: lower, upper: upper} ->
        [
          if(lower != 0.0, do: " LO BND  #{name}  #{fmt(lower)}\n", else: []),
          if(upper != :pos_inf, do: " UP BND  #{name}  #{fmt(upper)}\n", else: [])
        ]
    end)
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 6)
  defp fmt(n) when is_integer(n), do: :erlang.float_to_binary(n * 1.0, decimals: 6)
end
