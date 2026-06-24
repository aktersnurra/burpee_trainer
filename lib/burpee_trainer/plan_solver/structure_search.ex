defmodule BurpeeTrainer.PlanSolver.StructureSearch do
  @moduledoc """
  Generates readable unbroken block structures for Plan Solver v3.
  """

  alias BurpeeTrainer.PlanSolver.{BlockSpec, Infeasible, Input}

  @max_blocks 4
  @max_complete_structures 16

  @spec structures(Input.t()) :: {:ok, [[BlockSpec.t()]]} | {:error, Infeasible.t()}
  def structures(%Input{block_structure: blocks} = input) when is_list(blocks) and blocks != [] do
    with :ok <- validate_structure(blocks, input) do
      {:ok, [blocks]}
    end
  end

  def structures(%Input{} = input) do
    generated =
      input
      |> generated_structures()
      |> Enum.take(@max_complete_structures)

    case generated do
      [] -> {:ok, [balanced_fallback(input)]}
      structures -> {:ok, structures}
    end
  end

  @spec expand([BlockSpec.t()]) :: [pos_integer]
  def expand(blocks), do: Enum.flat_map(blocks, &BlockSpec.expand/1)

  @spec encode([BlockSpec.t()]) :: String.t()
  def encode(blocks), do: blocks |> Enum.map(&BlockSpec.encode/1) |> Enum.join("|")

  defp validate_structure(blocks, %Input{} = input) do
    set_pattern = expand(blocks)

    cond do
      Enum.sum(set_pattern) != input.burpee_count_target ->
        {:error,
         %Infeasible{
           reason: :advanced_structure_rep_mismatch,
           details: %{
             expected_reps: input.burpee_count_target,
             actual_reps: Enum.sum(set_pattern)
           },
           suggestions: ["Adjust the manual block structure to match the target reps"]
         }}

      Enum.any?(set_pattern, &(&1 > input.max_unbroken_reps)) ->
        {:error,
         %Infeasible{
           reason: :set_exceeds_max_unbroken,
           details: %{max_unbroken_reps: input.max_unbroken_reps, set_pattern: set_pattern},
           suggestions: ["Lower the reps in the manual block structure"]
         }}

      true ->
        :ok
    end
  end

  defp generated_structures(%Input{} = input) do
    uniform = uniform_structures(input.burpee_count_target, input.max_unbroken_reps)
    grammar = grammar_structures(input)
    fallback = [balanced_fallback(input)]

    (uniform ++ grammar ++ fallback)
    |> Enum.uniq_by(&encode/1)
    |> Enum.filter(&valid_generated_structure?(&1, input))
    |> Enum.sort_by(&structure_key/1)
  end

  defp valid_generated_structure?(structure, %Input{} = input) do
    set_pattern = expand(structure)

    Enum.sum(set_pattern) == input.burpee_count_target and
      Enum.all?(set_pattern, &(&1 <= input.max_unbroken_reps))
  end

  defp uniform_structures(target, max_unbroken_reps) do
    min_readable = min_readable_set(max_unbroken_reps)

    for set_size <- max_unbroken_reps..min_readable//-1,
        rem(target, set_size) == 0,
        set_count = div(target, set_size),
        set_count >= 2,
        {:ok, block} = BlockSpec.new(set_count, [set_size]) do
      [block]
    end
  end

  defp grammar_structures(%Input{} = input) do
    productions = block_productions(input.max_unbroken_reps)

    input.burpee_count_target
    |> search_blocks(productions, [], nil, [])
    |> Enum.reverse()
  end

  defp search_blocks(0, _productions, blocks, _previous_average, acc),
    do: [Enum.reverse(blocks) | acc]

  defp search_blocks(_remaining, _productions, blocks, _previous_average, acc)
       when length(blocks) >= @max_blocks or length(acc) >= @max_complete_structures,
       do: acc

  defp search_blocks(remaining, productions, blocks, previous_average, acc) do
    Enum.reduce_while(productions, acc, fn block, acc ->
      total = BlockSpec.total_reps(block)
      average = BlockSpec.average_reps(block)

      cond do
        length(acc) >= @max_complete_structures ->
          {:halt, acc}

        total > remaining ->
          {:cont, acc}

        previous_average && average > previous_average ->
          {:cont, acc}

        blocks != [] && BlockSpec.encode(hd(blocks)) == BlockSpec.encode(block) ->
          {:cont, acc}

        not representable?(remaining - total, productions, length(blocks) + 1) ->
          {:cont, acc}

        true ->
          next_acc = search_blocks(remaining - total, productions, [block | blocks], average, acc)

          if length(next_acc) >= @max_complete_structures do
            {:halt, next_acc}
          else
            {:cont, next_acc}
          end
      end
    end)
  end

  defp block_productions(max_unbroken_reps) do
    motifs =
      Enum.flat_map(max_unbroken_reps..1//-1, fn reps ->
        single = [[reps]]

        pairs =
          for other <- reps..1//-1,
              abs(reps - other) <= 1,
              do: [reps, other]

        single ++ pairs
      end)
      |> Enum.uniq()

    for motif <- motifs,
        repeat <- 1..12,
        {:ok, block} = BlockSpec.new(repeat, motif) do
      block
    end
    |> Enum.sort_by(fn block ->
      {-BlockSpec.average_reps(block), length(block.motif), -block.repeat,
       BlockSpec.encode(block)}
    end)
  end

  defp representable?(0, _productions, _blocks_used), do: true

  defp representable?(remaining, _productions, blocks_used)
       when remaining < 0 or blocks_used >= @max_blocks,
       do: false

  defp representable?(remaining, productions, blocks_used) do
    min_total = productions |> Enum.map(&BlockSpec.total_reps/1) |> Enum.min()
    max_total = productions |> Enum.map(&BlockSpec.total_reps/1) |> Enum.max()
    slots_left = @max_blocks - blocks_used

    remaining >= min_total and remaining <= max_total * slots_left
  end

  defp balanced_fallback(%Input{} = input) do
    target = input.burpee_count_target
    max_unbroken_reps = input.max_unbroken_reps
    set_count = ceil(target / max_unbroken_reps)
    base = div(target, set_count)
    remainder = rem(target, set_count)

    set_pattern =
      for index <- 1..set_count do
        if index <= remainder, do: base + 1, else: base
      end

    set_pattern
    |> Enum.sort(:desc)
    |> compress_sequence()
  end

  defp compress_sequence(set_pattern) do
    set_pattern
    |> Enum.chunk_by(& &1)
    |> Enum.map(fn chunk ->
      {:ok, block} = BlockSpec.new(length(chunk), [hd(chunk)])
      block
    end)
  end

  defp structure_key(structure) do
    set_pattern = expand(structure)

    {
      length(structure),
      length(Enum.uniq(set_pattern)),
      length(set_pattern),
      encode(structure)
    }
  end

  defp min_readable_set(max_unbroken_reps), do: max(max_unbroken_reps - 3, 1)
end
