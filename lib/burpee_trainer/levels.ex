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
    %{level: :level_4,   six_count: 275, navy_seal: 120},
    %{level: :level_3,   six_count: 250, navy_seal: 100},
    %{level: :level_2,   six_count: 200, navy_seal:  80},
    %{level: :level_1d,  six_count: 150, navy_seal:  60},
    %{level: :level_1c,  six_count: 100, navy_seal:  40},
    %{level: :level_1b,  six_count:  50, navy_seal:  20},
    %{level: :level_1a,  six_count:   1, navy_seal:   1}
  ]


  @doc """
  Returns the highest level where both types have qualifying sessions in
  the same ISO week. Returns `:level_1a` when no co-week pair exists.
  """
  @spec current_level([map]) :: atom
  def current_level(sessions) do
    found = Enum.find(@landmarks, fn lm ->
      co_week_achieved?(sessions, lm.six_count, lm.navy_seal)
    end)

    if found, do: found.level, else: :level_1a
  end

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

  @doc """
  Returns the next co-week landmark to reach for a given type, or `nil`
  if already graduated. Shows the per-type threshold for the next level.
  """
  @spec next_landmark([map], atom) ::
          %{level: atom, burpee_count_required: integer} | nil
  def next_landmark(sessions, burpee_type) do
    current = level_for_type(sessions, burpee_type)
    idx = Enum.find_index(@landmarks, fn %{level: l} -> l == current end)

    case idx do
      0 -> nil
      i ->
        next = Enum.at(@landmarks, i - 1)
        %{level: next.level, burpee_count_required: Map.get(next, burpee_type)}
    end
  end

  @doc """
  Returns `true` if any qualifying session for the given type meets the
  threshold for the given level (per-type check, no co-week requirement).
  """
  @spec landmark_achieved?([map], atom, atom) :: boolean
  def landmark_achieved?(sessions, burpee_type, level) do
    qualifying =
      sessions
      |> Enum.filter(&(&1.burpee_type == burpee_type))
      |> Enum.filter(&qualifies?/1)

    threshold =
      Enum.find_value(@landmarks, fn %{level: l} = lm ->
        if l == level, do: Map.get(lm, burpee_type)
      end)

    is_integer(threshold) and Enum.any?(qualifying, &(&1.burpee_count_actual >= threshold))
  end

  @doc """
  Returns a chronological list of co-week level unlocks. An entry is
  created only when both types' thresholds are first met in the same
  ISO week. The `session_id` is the later of the two sessions in that
  week (the one that "completed" the pair).
  """
  @spec landmark_history([map]) :: [
          %{level: atom, session_id: integer, date_unlocked: Date.t()}
        ]
  def landmark_history(sessions) do
    for %{level: level, six_count: six_threshold, navy_seal: navy_threshold} <- @landmarks,
        entry = first_co_week_unlock(sessions, six_threshold, navy_threshold),
        not is_nil(entry) do
      Map.put(entry, :level, level)
    end
    |> Enum.sort_by(& &1.date_unlocked)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp co_week_achieved?(sessions, six_threshold, navy_threshold) do
    six_weeks = qualifying_week_keys(sessions, :six_count, six_threshold)
    navy_weeks = qualifying_week_keys(sessions, :navy_seal, navy_threshold)
    not MapSet.disjoint?(six_weeks, navy_weeks)
  end

  defp qualifying_week_keys(sessions, burpee_type, threshold) do
    sessions
    |> Enum.filter(&(&1.burpee_type == burpee_type))
    |> Enum.filter(&qualifies?/1)
    |> Enum.filter(&(&1.burpee_count_actual >= threshold))
    |> MapSet.new(&week_key/1)
  end

  # Find the earliest ISO week where both types have a qualifying session,
  # and return the later session's id and date as the "completing" entry.
  defp first_co_week_unlock(sessions, six_threshold, navy_threshold) do
    six_by_week = latest_qualifying_by_week(sessions, :six_count, six_threshold)
    navy_by_week = latest_qualifying_by_week(sessions, :navy_seal, navy_threshold)

    common_weeks =
      MapSet.intersection(
        MapSet.new(Map.keys(six_by_week)),
        MapSet.new(Map.keys(navy_by_week))
      )

    case Enum.min_by(common_weeks, & &1, fn -> nil end) do
      nil ->
        nil

      week ->
        {six_date, six_dt, six_id} = six_by_week[week]
        {navy_date, navy_dt, navy_id} = navy_by_week[week]

        if DateTime.compare(six_dt, navy_dt) != :lt,
          do: %{session_id: six_id, date_unlocked: six_date},
          else: %{session_id: navy_id, date_unlocked: navy_date}
    end
  end

  # Returns a map of ISO week key => {date, datetime, session_id} for the
  # latest qualifying session in each week for the given type and threshold.
  defp latest_qualifying_by_week(sessions, burpee_type, threshold) do
    sessions
    |> Enum.filter(&(&1.burpee_type == burpee_type))
    |> Enum.filter(&qualifies?/1)
    |> Enum.filter(&(&1.burpee_count_actual >= threshold))
    |> Enum.group_by(&week_key/1)
    |> Map.new(fn {week, week_sessions} ->
      last = Enum.max_by(week_sessions, & &1.inserted_at, DateTime)
      {week, {DateTime.to_date(last.inserted_at), last.inserted_at, last.id}}
    end)
  end

  defp week_key(session) do
    :calendar.iso_week_number(Date.to_erl(DateTime.to_date(session.inserted_at)))
  end

  defp qualifies?(%{duration_sec_actual: d, burpee_count_actual: n})
       when is_integer(d) and is_integer(n),
       do: d <= 1200 and n >= 1

  defp qualifies?(_), do: false
end
