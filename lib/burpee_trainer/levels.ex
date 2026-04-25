defmodule BurpeeTrainer.Levels do
  @moduledoc """
  Pure functional level derivation. No Ecto, no side effects.

  Levels are derived from sessions at read time and never stored.
  A session qualifies for a landmark when `duration_sec_actual <= 1200`
  and `burpee_count_actual >= threshold`.

  `current_level/1` returns the *lower* of the two per-type levels,
  because both burpee types must progress together to advance.
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

  # Ascending order used for level comparison.
  @level_order [:level_1a, :level_1b, :level_1c, :level_1d, :level_2, :level_3, :level_4, :graduated]

  @doc """
  Returns the overall level — the lower of the per-type levels for
  `:six_count` and `:navy_seal`. Returns `:level_1a` with zero sessions.
  """
  @spec current_level([map]) :: atom
  def current_level(sessions) do
    lower_of(level_for_type(sessions, :six_count), level_for_type(sessions, :navy_seal))
  end

  @doc """
  Returns the highest landmark level achieved for a given burpee type.
  Returns `:level_1a` when no qualifying sessions exist for that type.
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
  Returns the next landmark to reach for a given type, or `nil` if
  already graduated.
  """
  @spec next_landmark([map], atom) ::
          %{level: atom, burpee_count_required: integer} | nil
  def next_landmark(sessions, burpee_type) do
    current = level_for_type(sessions, burpee_type)
    idx = Enum.find_index(@landmarks, fn %{level: l} -> l == current end)

    case idx do
      0 ->
        nil

      i ->
        next = Enum.at(@landmarks, i - 1)
        %{level: next.level, burpee_count_required: Map.get(next, burpee_type)}
    end
  end

  @doc """
  Returns `true` if any qualifying session meets the threshold for the
  given burpee type and level.
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
  Returns a chronological list of every landmark first achieved,
  across both burpee types.
  """
  @spec landmark_history([map]) :: [
          %{level: atom, burpee_type: atom, session_id: integer, date_unlocked: Date.t()}
        ]
  def landmark_history(sessions) do
    for burpee_type <- [:six_count, :navy_seal],
        %{level: level} = lm <- @landmarks,
        threshold = Map.get(lm, burpee_type),
        first =
          sessions
          |> Enum.filter(&(&1.burpee_type == burpee_type))
          |> Enum.filter(&qualifies?/1)
          |> Enum.filter(&(&1.burpee_count_actual >= threshold))
          |> Enum.sort_by(& &1.inserted_at)
          |> List.first(),
        not is_nil(first) do
      %{
        level: level,
        burpee_type: burpee_type,
        session_id: first.id,
        date_unlocked: DateTime.to_date(first.inserted_at)
      }
    end
    |> Enum.sort_by(& &1.date_unlocked)
  end

  # A session qualifies if it was done within 20 minutes with at least 1 rep.
  defp qualifies?(%{duration_sec_actual: d, burpee_count_actual: n})
       when is_integer(d) and is_integer(n),
       do: d <= 1200 and n >= 1

  defp qualifies?(_), do: false

  defp lower_of(a, b) do
    ia = Enum.find_index(@level_order, &(&1 == a))
    ib = Enum.find_index(@level_order, &(&1 == b))
    if ia <= ib, do: a, else: b
  end
end
