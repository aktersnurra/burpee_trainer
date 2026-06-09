defmodule BurpeeTrainer.Planning.TimelineItem.StandaloneRest do
  @moduledoc "Explicit reset rest funded by tighter work elsewhere."
  @enforce_keys [:id, :start_sec, :duration_sec]
  defstruct [:id, :start_sec, :duration_sec, funded_by: []]

  @type t :: %__MODULE__{
          id: String.t(),
          start_sec: non_neg_integer(),
          duration_sec: pos_integer(),
          funded_by: [String.t()]
        }
end
