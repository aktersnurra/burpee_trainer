defmodule BurpeeTrainer.Planning.StyleProfile do
  @moduledoc "Style semantics derived from a planner goal."

  alias BurpeeTrainer.Planning.Goal

  @enforce_keys [:style, :rest_semantics]
  defstruct [:style, :rest_semantics, :preferred_unit_sec, :max_reps_per_set]

  @type rest_semantics :: :between_reps | :after_set

  @type t :: %__MODULE__{
          style: Goal.style(),
          rest_semantics: rest_semantics(),
          preferred_unit_sec: pos_integer() | nil,
          max_reps_per_set: pos_integer() | nil
        }

  @spec from_goal(Goal.t()) :: t()
  def from_goal(%Goal{style: :even} = goal) do
    %__MODULE__{
      style: :even,
      rest_semantics: :between_reps,
      preferred_unit_sec: goal.preferred_unit_sec,
      max_reps_per_set: nil
    }
  end

  def from_goal(%Goal{style: :unbroken} = goal) do
    %__MODULE__{
      style: :unbroken,
      rest_semantics: :after_set,
      preferred_unit_sec: nil,
      max_reps_per_set: goal.max_reps_per_set
    }
  end
end
