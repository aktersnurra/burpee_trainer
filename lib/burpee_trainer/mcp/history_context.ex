defmodule BurpeeTrainer.Mcp.HistoryContext do
  @moduledoc "Selection boundaries and response coverage, not a repeatable snapshot."
  alias BurpeeTrainer.Mcp.Sessions
  alias BurpeeTrainer.UserTime

  @doc "`page` is `more?:` (a later page remains) and `cursor?:` (this is a later page)."
  @spec build(map(), map(), map(), non_neg_integer(), non_neg_integer(), keyword()) :: map()
  def build(args, user, filters, returned, excluded, page \\ []) do
    more? = Keyword.get(page, :more?, false)
    complete? = not more? and not Keyword.get(page, :cursor?, false)
    cutoff = cutoff(filters)

    %{
      "applied_filters" =>
        filters
        |> Map.drop([:from, :before, :as_of])
        |> Map.new(fn {key, value} -> {to_string(key), value} end),
      "requested_filters" => Map.take(args, Sessions.filter_keys()),
      "timezone" => user.timezone,
      "from_utc_inclusive" => iso(filters[:from]),
      "to_utc_exclusive" => iso(filters[:before]),
      "effective_utc_cutoff" => iso(cutoff),
      "cutoff_inclusive" =>
        filters[:before] == nil or DateTime.compare(filters.before, filters.as_of) == :gt,
      "as_of" => iso(filters.as_of),
      "returned_sessions" => returned,
      "matched_sessions" => if(complete?, do: returned),
      "excluded_non_authoritative_sessions" => excluded,
      "continuation_exhausted" => not more?,
      "complete_range" => complete?
    }
  end

  @spec partial?(Date.t(), Date.t(), map(), String.t()) :: boolean()
  def partial?(start, finish, filters, timezone) do
    {:ok, beginning} = UserTime.resolve_local(start, ~T[00:00:00], timezone)
    {:ok, ending} = UserTime.resolve_local(Date.add(finish, 1), ~T[00:00:00], timezone)

    (filters[:from] != nil and DateTime.compare(filters.from, beginning) == :gt) or
      DateTime.compare(cutoff(filters), ending) == :lt
  end

  defp cutoff(%{before: before, as_of: now}) do
    if DateTime.compare(before, now) == :lt, do: before, else: now
  end

  defp cutoff(%{as_of: now}), do: now
  defp iso(nil), do: nil
  defp iso(at), do: DateTime.to_iso8601(at)
end
