defmodule BurpeeTrainer.Home.Facts do
  @moduledoc "Everything Home needs to decide what to show, loaded once per render cycle."

  @enforce_keys [:slot, :started_session, :selection, :history?, :owned_plan?, :results]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slot: map(),
          started_session: map() | nil,
          selection: map() | nil,
          history?: boolean(),
          owned_plan?: boolean(),
          results: map()
        }
end
