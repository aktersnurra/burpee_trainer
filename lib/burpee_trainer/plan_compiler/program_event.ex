defmodule BurpeeTrainer.PlanCompiler.ProgramEvent do
  @moduledoc "One executable instruction in a compiled workout program."

  alias BurpeeTrainer.PlanCompiler.ProgramEvent.{Rest, Work}

  @type t :: Work.t() | Rest.t()

  @spec work!(map()) :: Work.t()
  def work!(attrs) when is_map(attrs) do
    reject_unknown!(attrs, [:reps, :sec_per_rep], :work)

    %Work{
      kind: :work,
      reps: fetch!(attrs, :reps),
      sec_per_rep: fetch!(attrs, :sec_per_rep) * 1.0
    }
  end

  @spec rest!(map()) :: Rest.t()
  def rest!(attrs) when is_map(attrs) do
    reject_unknown!(attrs, [:duration_sec], :rest)

    %Rest{
      kind: :rest,
      duration_sec: fetch!(attrs, :duration_sec)
    }
  end

  defp reject_unknown!(attrs, allowed_keys, event_kind) do
    unknown_keys =
      attrs
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_keys))
      |> Enum.sort()

    if unknown_keys != [] do
      raise ArgumentError, "unknown #{event_kind} event fields: #{inspect(unknown_keys)}"
    end
  end

  defp fetch!(attrs, key) do
    Map.fetch!(attrs, key)
  end
end
