defmodule BurpeeTrainer.PlanCompiler.ProgramEvent do
  @moduledoc "One executable instruction in a compiled workout program."

  alias BurpeeTrainer.PlanCompiler.ProgramEvent.{Rest, Work}

  @type t :: Work.t() | Rest.t()

  @spec work!(map()) :: Work.t()
  def work!(attrs) when is_map(attrs) do
    %Work{
      id: fetch!(attrs, :id),
      kind: :work,
      set_index: fetch!(attrs, :set_index),
      block_index: Map.get(attrs, :block_index),
      display_group: Map.get(attrs, :display_group),
      reps: fetch!(attrs, :reps),
      sec_per_rep: fetch!(attrs, :sec_per_rep) * 1.0,
      label: fetch!(attrs, :label)
    }
  end

  @spec rest!(map()) :: Rest.t()
  def rest!(attrs) when is_map(attrs) do
    %Rest{
      id: fetch!(attrs, :id),
      kind: :rest,
      duration_sec: fetch!(attrs, :duration_sec),
      label: fetch!(attrs, :label),
      source: Map.get(attrs, :source)
    }
  end

  defp fetch!(attrs, key) do
    Map.fetch!(attrs, key)
  end
end
