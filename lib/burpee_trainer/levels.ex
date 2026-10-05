defmodule BurpeeTrainer.Levels do
  @moduledoc """
  Pure functional level derivation. No Ecto, no side effects.

  Levels are derived from sessions at read time and never stored.
  A session qualifies for a landmark when `duration_sec_actual <= 1200`
  and `burpee_count_actual >= threshold`.

  A level is *achieved* only when both `:six_count` and `:navy_seal`
  threshold sessions occur within the same ISO calendar week. Doing
  navy seal Level 2 in week 1 and six-count Level 2 in week 2 does
  not grant Level 2.

  `level_for_type/2` still returns the highest per-type level regardless
  of the co-week requirement — useful for showing individual progress and
  identifying which type is the bottleneck.
  """

  @landmarks [
    %{level: :graduated, six_count: 325, navy_seal: 150},
    %{level: :level_4, six_count: 275, navy_seal: 120},
    %{level: :level_3, six_count: 250, navy_seal: 100},
    %{level: :level_2, six_count: 200, navy_seal: 80},
    %{level: :level_1d, six_count: 150, navy_seal: 60},
    %{level: :level_1c, six_count: 100, navy_seal: 40},
    %{level: :level_1b, six_count: 50, navy_seal: 20},
    %{level: :level_1a, six_count: 1, navy_seal: 1}
  ]

  @doc "All valid level atoms, ordered from highest to lowest."
  @spec all_levels() :: [atom]
  def all_levels, do: Enum.map(@landmarks, & &1.level)

  @spec threshold(atom(), :six_count | :navy_seal) :: pos_integer()
  def threshold(level, burpee_type) when burpee_type in [:six_count, :navy_seal] do
    @landmarks
    |> Enum.find(&(&1.level == level))
    |> case do
      nil -> raise ArgumentError, "unknown level: #{inspect(level)}"
      landmark -> Map.fetch!(landmark, burpee_type)
    end
  end

  # A level must be *maintained*: the most recent co-week pair demonstrating
  # it has to fall within this many days of `today`, otherwise it decays.
  # Graduated is given a longer grace period than the climbing levels.
  @graduated_window_days 30
  @default_window_days 14

  @doc "Maintenance window (in days) before a level decays."
  @spec window_days(atom) :: pos_integer
  def window_days(:graduated), do: @graduated_window_days
  def window_days(_level), do: @default_window_days

  @doc """
  Returns the highest level where both types have a qualifying session in the
  same ISO week *and* that pair was completed recently enough to still count
  (see `window_days/1`). Returns `:level_1a` when no maintained pair exists.

  `:level_1a` is the floor and never decays.
  """
  @spec current_level([map], Date.t()) :: atom
  def current_level(sessions, today \\ Date.utc_today()) do
    found =
      Enum.find(@landmarks, fn lm ->
        case latest_co_week_completion(sessions, lm.six_count, lm.navy_seal) do
          nil -> false
          date -> Date.diff(today, date) <= window_days(lm.level)
        end
      end)

    if found, do: found.level, else: :level_1a
  end

  @doc """
  Returns the level tag for a plan given its total rep count and burpee type.
  Filters to landmarks where count >= threshold, then picks the one with the
  highest threshold. Returns `:level_1a` when count is below all thresholds.
  """
  @spec level_for_count(atom, integer) :: atom
  def level_for_count(burpee_type, count) when is_integer(count) do
    @landmarks
    |> Enum.filter(fn lm -> count >= Map.get(lm, burpee_type) end)
    |> Enum.max_by(fn lm -> Map.get(lm, burpee_type) end, fn -> nil end)
    |> case do
      nil -> :level_1a
      lm -> lm.level
    end
  end

  def level_for_count(_burpee_type, _), do: :level_1a

  @doc """
  Returns the highest landmark level achieved for a given burpee type,
  ignoring the co-week requirement. Returns `:level_1a` with no sessions.
  """
  @spec level_for_type([map], atom) :: atom
  def level_for_type(sessions, burpee_type) do
    qualifying =
      sessions
      |> Enum.filter(&(&1.burpee_type == burpee_type))
      |> Enum.filter(&qualifies?/1)

    Enum.find_value(@landmarks, :level_1a, fn %{level: level} = lm ->
      threshold = Map.get(lm, burpee_type)
      if Enum.any?(qualifying, &(&1.burpee_count_actual >= threshold)), do: level
    end)
  end

  defp latest_co_week_completion(sessions, six_threshold, navy_threshold) do
    six_by_week = latest_qualifying_by_week(sessions, :six_count, six_threshold)
    navy_by_week = latest_qualifying_by_week(sessions, :navy_seal, navy_threshold)

    common_weeks =
      MapSet.intersection(
        MapSet.new(Map.keys(six_by_week)),
        MapSet.new(Map.keys(navy_by_week))
      )

    common_weeks
    |> Enum.map(fn week ->
      {six_date, _six_dt, _six_id} = six_by_week[week]
      {navy_date, _navy_dt, _navy_id} = navy_by_week[week]
      Enum.max([six_date, navy_date], Date)
    end)
    |> case do
      [] -> nil
      dates -> Enum.max(dates, Date)
    end
  end

  # Find the earliest ISO week where both types have a qualifying session,
  # and return the later session's id and date as the "completing" entry.
  defp latest_qualifying_by_week(sessions, burpee_type, threshold) do
    sessions
    |> Enum.filter(&(&1.burpee_type == burpee_type))
    |> Enum.filter(&qualifies?/1)
    |> Enum.filter(&(&1.burpee_count_actual >= threshold))
    |> Enum.group_by(&week_key/1)
    |> Map.new(fn {week, week_sessions} ->
      last = Enum.max_by(week_sessions, & &1.completed_at, DateTime)
      {week, {DateTime.to_date(last.completed_at), last.completed_at, last.id}}
    end)
  end

  defp week_key(session) do
    :calendar.iso_week_number(Date.to_erl(DateTime.to_date(session.completed_at)))
  end

  defp qualifies?(%{duration_sec_actual: d, burpee_count_actual: n})
       when is_integer(d) and is_integer(n),
       do: d <= 1200 and n >= 1

  defp qualifies?(_), do: false
end
