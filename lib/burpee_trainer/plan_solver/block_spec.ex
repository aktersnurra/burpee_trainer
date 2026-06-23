defmodule BurpeeTrainer.PlanSolver.BlockSpec do
  @moduledoc """
  Readable repeated block motif used by Plan Solver v3.
  """

  @enforce_keys [:repeat, :motif]
  defstruct @enforce_keys

  @type t :: %__MODULE__{repeat: pos_integer, motif: [pos_integer]}

  @spec new(term, term) :: {:ok, t()} | {:error, term}
  def new(repeat, _motif) when not is_integer(repeat) or repeat < 1,
    do: {:error, {:invalid_repeat, repeat}}

  def new(_repeat, motif) when not is_list(motif) or motif == [] or length(motif) > 2,
    do: {:error, {:invalid_motif, motif}}

  def new(repeat, motif) do
    invalid = Enum.find(motif, &(not is_integer(&1) or &1 < 1))

    if invalid do
      {:error, {:invalid_rep_count, invalid}}
    else
      {:ok, %__MODULE__{repeat: repeat, motif: motif}}
    end
  end

  @spec expand(t()) :: [pos_integer]
  def expand(%__MODULE__{repeat: repeat, motif: motif}) do
    motif
    |> List.duplicate(repeat)
    |> List.flatten()
  end

  @spec total_reps(t()) :: pos_integer
  def total_reps(%__MODULE__{} = block), do: block |> expand() |> Enum.sum()

  @spec set_count(t()) :: pos_integer
  def set_count(%__MODULE__{repeat: repeat, motif: motif}), do: repeat * length(motif)

  @spec average_reps(t()) :: float
  def average_reps(%__MODULE__{} = block), do: total_reps(block) / set_count(block)

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{repeat: repeat, motif: motif}) do
    "#{repeat}x[#{Enum.join(motif, ",")}]"
  end
end
