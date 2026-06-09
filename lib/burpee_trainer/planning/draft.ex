defmodule BurpeeTrainer.Planning.Draft do
  @moduledoc "Solved user-facing workout draft prescription."

  alias BurpeeTrainer.Planning.{Feedback, Goal, TimelineItem}

  @enforce_keys [:goal, :status, :timeline, :metadata]
  defstruct [
    :goal,
    :status,
    :timeline,
    :feedback,
    repairs: [],
    changed_item_ids: [],
    metadata: %{}
  ]

  @type status :: :good | :adjusted | :tight | :infeasible

  @type t :: %__MODULE__{
          goal: Goal.t(),
          status: status(),
          timeline: [TimelineItem.t()],
          feedback: Feedback.Message.t() | nil,
          repairs: [Feedback.Repair.t()],
          changed_item_ids: [String.t()],
          metadata: map()
        }
end
