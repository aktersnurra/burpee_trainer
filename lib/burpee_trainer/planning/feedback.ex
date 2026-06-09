defmodule BurpeeTrainer.Planning.Feedback do
  @moduledoc "Structured draft feedback and repair suggestions."

  alias BurpeeTrainer.Planning.Feedback.{Message, Repair}

  @type message :: Message.t()
  @type repair :: Repair.t()
end
