defmodule BurpeeTrainer.Planning.TimelineItem do
  @moduledoc """
  Semantic user-facing draft timeline items.

  These are planning concepts, not database rows. Compile them to execution
  steps only after a draft is verified.
  """

  @type t ::
          BurpeeTrainer.Planning.TimelineItem.EvenUnit.t()
          | BurpeeTrainer.Planning.TimelineItem.UnbrokenGroup.t()
          | BurpeeTrainer.Planning.TimelineItem.StandaloneRest.t()
          | BurpeeTrainer.Planning.TimelineItem.MeaningfulPattern.t()
end
