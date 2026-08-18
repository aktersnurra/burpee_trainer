defmodule BurpeeTrainer.Workouts.Error do
  @moduledoc "Structured workout-library error."

  @enforce_keys [:code, :context]
  defstruct @enforce_keys

  @type t :: %__MODULE__{code: atom(), context: map()}

  @spec new(atom(), map()) :: t()
  def new(code, context \\ %{}) when is_atom(code) and is_map(context) do
    %__MODULE__{code: code, context: context}
  end
end
