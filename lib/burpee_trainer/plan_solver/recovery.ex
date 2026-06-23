defmodule BurpeeTrainer.PlanSolver.Recovery do
  @moduledoc "Canonical recovery after an unbroken set."

  @enforce_keys [:after_set, :total_sec, :kind, :source]
  defstruct @enforce_keys

  @type kind :: :normal | :reset | :explicit
  @type source :: :auto_normal | {:auto_reset, :mid | :late} | {:explicit, pos_integer}
  @type t :: %__MODULE__{after_set: pos_integer, total_sec: number, kind: kind, source: source}
end
