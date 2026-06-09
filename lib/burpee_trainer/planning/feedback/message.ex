defmodule BurpeeTrainer.Planning.Feedback.Message do
  @moduledoc "Short feedback for the bottom bar."

  @enforce_keys [:kind, :text]
  defstruct [:kind, :text, changed_item_ids: []]

  @type kind :: :adjusted | :tight | :infeasible
  @type t :: %__MODULE__{kind: kind(), text: String.t(), changed_item_ids: [String.t()]}
end
