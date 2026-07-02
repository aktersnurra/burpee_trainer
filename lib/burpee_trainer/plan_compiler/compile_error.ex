defmodule BurpeeTrainer.PlanCompiler.CompileError do
  @moduledoc "Structured compiler/program validation error."

  @enforce_keys [:code, :message, :context]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          context: map()
        }

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, context \\ %{}) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, context: context}
  end
end
