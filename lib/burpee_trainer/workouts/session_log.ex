defmodule BurpeeTrainer.Workouts.SessionLog do
  @moduledoc """
  Boundary helpers for free-form workout log params.

  LiveViews receive string-keyed params and UI assigns. This module normalizes
  those dynamic values into the attrs shape expected by `WorkoutSession` changesets.
  """

  @type attrs :: %{String.t() => term()}

  @spec parse_log_date(map(), Date.t()) :: Date.t()
  def parse_log_date(params, %Date{} = fallback) when is_map(params) do
    case Date.from_iso8601(params["log_date"] || "") do
      {:ok, date} -> date
      _error -> fallback
    end
  end

  @spec to_attrs(map(), atom(), integer(), [String.t()], Date.t()) :: attrs()
  def to_attrs(params, burpee_type, mood, tags, %Date{} = log_date)
      when is_map(params) and is_atom(burpee_type) and is_integer(mood) and is_list(tags) do
    params
    |> Map.put("burpee_type", Atom.to_string(burpee_type))
    |> Map.put("mood", Integer.to_string(mood))
    |> Map.put("tags", tags |> Enum.sort() |> Enum.join(","))
    |> Map.put("duration_sec_actual", duration_seconds(params["duration_sec_actual"]))
    |> Map.put("inserted_at", DateTime.new!(log_date, ~T[12:00:00], "Etc/UTC"))
  end

  defp duration_seconds(value) do
    case Integer.parse(value || "") do
      {minutes, ""} -> Integer.to_string(minutes * 60)
      _error -> value
    end
  end
end
