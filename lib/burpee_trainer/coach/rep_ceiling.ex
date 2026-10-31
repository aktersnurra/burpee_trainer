defmodule BurpeeTrainer.Coach.RepCeiling do
  @moduledoc """
  The most reps the planner may plan for a burpee type, whether it designs a workout or
  picks a saved one. The athlete's recent best decides: 10% above their best 20-minute pace
  for the type in the last eight weeks, whatever their level. Only with no session of the
  type in that time does the level after their current one cap it. Easier is always
  allowed. A longer slot (weekend catch-up) is compared at its 20-minute-equivalent pace.
  """

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.{Levels, UserTime, Workouts}

  # Level landmarks and the recent best are counts for a 20-minute session.
  @landmark_duration_sec 1_200
  @recent_days 56
  @headroom_pct 110

  @type t :: {:recent_best, pos_integer()} | {:level, non_neg_integer()}

  @doc "The ceiling for `burpee_type` now."
  @spec for_type(Scope.t(), atom()) :: {:ok, t()} | {:error, :timezone_unavailable}
  def for_type(%Scope{} = scope, burpee_type) do
    case recent_best(scope, burpee_type) do
      best when best > 0 ->
        {:ok, {:recent_best, div(best * @headroom_pct, 100)}}

      _none ->
        case UserTime.context(scope.user, DateTime.utc_now()) do
          {:ok, %{date: today}} ->
            current = Levels.current_level(Workouts.list_sessions(scope), today)
            {:ok, {:level, rank(current) + 1}}

          {:error, _} ->
            {:error, :timezone_unavailable}
        end
    end
  end

  @doc "Whether `reps` in `duration_sec` stay within the ceiling."
  @spec allows?(t(), atom(), non_neg_integer(), pos_integer()) :: boolean()
  def allows?({:recent_best, cap}, _burpee_type, reps, duration_sec),
    do: pace(reps, duration_sec) <= cap

  def allows?({:level, max_rank}, burpee_type, reps, duration_sec),
    do: rank(Levels.level_for_count(burpee_type, pace(reps, duration_sec))) <= max_rank

  @doc "Reps per 20 minutes; a session shorter than 20 minutes counts as its own reps."
  @spec pace(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def pace(reps, duration_sec),
    do: div(reps * @landmark_duration_sec, max(duration_sec, @landmark_duration_sec))

  @doc "The athlete's best reps per 20 minutes in the last eight weeks, per burpee type; nil for none."
  @spec recent_bests(Scope.t()) :: %{atom() => pos_integer() | nil}
  def recent_bests(%Scope{} = scope) do
    sessions = Workouts.list_sessions(scope)

    Map.new([:six_count, :navy_seal], fn type ->
      best = sessions |> Enum.filter(&(&1.burpee_type == type)) |> best()
      {type, if(best > 0, do: best)}
    end)
  end

  defp recent_best(scope, burpee_type),
    do: scope |> Workouts.list_sessions(burpee_type) |> best()

  defp best(sessions) do
    since = DateTime.add(DateTime.utc_now(), -@recent_days, :day)

    sessions
    |> Enum.filter(
      &(DateTime.compare(&1.completed_at, since) != :lt and
          is_integer(&1.burpee_count_actual) and is_integer(&1.duration_sec_actual))
    )
    |> Enum.map(&pace(&1.burpee_count_actual, &1.duration_sec_actual))
    |> Enum.max(fn -> 0 end)
  end

  # Levels.all_levels/0 runs from highest to lowest; a rank counts up from level_1a.
  defp rank(level), do: Levels.all_levels() |> Enum.reverse() |> Enum.find_index(&(&1 == level))
end
