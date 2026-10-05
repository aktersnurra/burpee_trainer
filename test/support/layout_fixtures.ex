defmodule BurpeeTrainer.LayoutFixtures do
  @moduledoc "Provider-response layouts for authoring tests."

  @doc "One phase per entry; each entry contains `{reps, cadence, active}` sets."
  def layout(phases, name \\ "Test workout") do
    %{
      "name" => name,
      "rationale" => "Test layout.",
      "phases" =>
        Enum.map(phases, fn sets ->
          %{
            "sets" =>
              Enum.map(sets, fn {reps, cadence, active} ->
                %{"reps" => reps, "sec_per_rep" => cadence, "sec_per_burpee" => active}
              end),
            "rest_weights" => List.duplicate(1, length(sets) - 1)
          }
        end)
    }
  end
end
