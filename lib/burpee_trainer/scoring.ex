defmodule BurpeeTrainer.Scoring do
  @moduledoc """
  Pure push-up scoring. No Ecto, no side effects.

  A burpee is worth a number of push-ups depending on its type:
  a six-count burpee is one push-up, a navy seal burpee is three.
  This lets the two disciplines share a single comparable score.

  Functions here operate on plain session maps shaped like:

      %{
        burpee_type: :six_count | :navy_seal,
        burpee_count_actual: integer,
        duration_sec_actual: integer,
        inserted_at: DateTime.t(),
        tags: String.t() | nil
      }

  Warmup sessions (`tags == "warmup"`) are excluded from every aggregate,
  matching `Workouts.weekly_minutes/1`.
  """

  @pushups_per_burpee %{six_count: 1, navy_seal: 3}
  @weekly_minutes_goal 80
  # Each type must contribute at least this share of the week's training
  # minutes for the week to count as "balanced".
  @balance_min_share 0.4

  @doc "Push-ups per burpee for a given type."
  @spec pushups_per_burpee(atom) :: pos_integer
  def pushups_per_burpee(type), do: Map.fetch!(@pushups_per_burpee, type)

  @doc "Push-up value of `count` burpees of `type`."
  @spec pushups(atom, integer) :: non_neg_integer
  def pushups(type, count) when is_integer(count) and count >= 0,
    do: count * pushups_per_burpee(type)

  @doc "Push-up value of a single session map (0 for warmup or malformed)."
  @spec session_pushups(map) :: non_neg_integer
  def session_pushups(%{tags: "warmup"}), do: 0

  def session_pushups(%{burpee_type: type, burpee_count_actual: count})
      when is_atom(type) and is_integer(count) and count >= 0,
      do: pushups(type, count)

  def session_pushups(_), do: 0

  @doc """
  Total push-ups across `sessions` (warmup excluded).
  """
  @spec total_pushups([map]) :: non_neg_integer
  def total_pushups(sessions) do
    sessions
    |> Enum.reject(&warmup?/1)
    |> Enum.reduce(0, fn s, acc -> acc + session_pushups(s) end)
  end

  @doc """
  Per-ISO-week push-up totals (Mon–Sun), sorted descending by `week_start`.
  Warmup sessions are excluded.
  """
  @spec weekly_pushups([map]) :: [%{week_start: Date.t(), pushups: non_neg_integer}]
  def weekly_pushups(sessions) do
    sessions
    |> Enum.reject(&warmup?/1)
    |> Enum.group_by(fn %{inserted_at: dt} ->
      dt |> DateTime.to_date() |> Date.beginning_of_week(:monday)
    end)
    |> Enum.map(fn {week_start, rows} ->
      %{week_start: week_start, pushups: total_pushups(rows)}
    end)
    |> Enum.sort_by(& &1.week_start, {:desc, Date})
  end

  @doc """
  Push-up total for the ISO week containing `date` (warmup excluded).
  """
  @spec week_pushups([map], Date.t()) :: non_neg_integer
  def week_pushups(sessions, date) do
    week_start = Date.beginning_of_week(date, :monday)

    sessions
    |> Enum.reject(&warmup?/1)
    |> Enum.filter(fn %{inserted_at: dt} ->
      Date.compare(DateTime.to_date(dt) |> Date.beginning_of_week(:monday), week_start) == :eq
    end)
    |> total_pushups()
  end

  @doc """
  Training balance for a set of (single-week) sessions, by minutes per type.

  Returns `%{six_min, navy_min, total_min, ratio, balanced?}` where `ratio`
  is the smaller share over the larger (0.0–1.0) and `balanced?` is true when
  the week met the 80-minute goal *and* each type contributed at least 40% of
  the training time.
  """
  @spec balance([map]) :: %{
          six_min: float,
          navy_min: float,
          total_min: float,
          ratio: float,
          balanced?: boolean
        }
  def balance(sessions) do
    active = Enum.reject(sessions, &warmup?/1)
    six_min = type_minutes(active, :six_count)
    navy_min = type_minutes(active, :navy_seal)
    total = six_min + navy_min

    ratio =
      cond do
        total <= 0 -> 0.0
        six_min == 0 or navy_min == 0 -> 0.0
        true -> min(six_min, navy_min) / max(six_min, navy_min)
      end

    balanced? =
      total >= @weekly_minutes_goal and
        six_min >= @balance_min_share * total and
        navy_min >= @balance_min_share * total

    %{six_min: six_min, navy_min: navy_min, total_min: total, ratio: ratio, balanced?: balanced?}
  end

  @doc "Whether `sessions` (assumed one week) form a balanced week."
  @spec balanced_week?([map]) :: boolean
  def balanced_week?(sessions), do: balance(sessions).balanced?

  defp type_minutes(sessions, type) do
    sessions
    |> Enum.filter(&(&1.burpee_type == type))
    |> Enum.reduce(0, fn s, acc -> acc + (s.duration_sec_actual || 0) end)
    |> Kernel./(60.0)
  end

  defp warmup?(%{tags: "warmup"}), do: true
  defp warmup?(_), do: false
end
