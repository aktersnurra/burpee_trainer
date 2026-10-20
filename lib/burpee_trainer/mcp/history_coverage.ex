defmodule BurpeeTrainer.Mcp.HistoryCoverage do
  @moduledoc "Complete aggregate retrieval; refuses a truncated page."
  alias BurpeeTrainer.Workouts

  @spec fetch(BurpeeTrainer.Accounts.Scope.t(), map(), pos_integer()) ::
          {:ok, [map()]} | {:error, String.t()}
  def fetch(scope, filters, limit \\ 100_000) do
    case Workouts.list_sessions_page(scope, limit, filters: filters) do
      {_rows, true} ->
        {:error, "History exceeds #{limit} sessions; narrow your date range or filters."}

      {rows, false} when is_list(rows) ->
        {:ok, rows}

      {:error, _} ->
        {:error, "history is not available"}
    end
  end
end
