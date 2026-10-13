defmodule BurpeeTrainerWeb.Fmt do
  @moduledoc """
  Small presentation helpers — duration formatting, burpee-type labels,
  etc. Kept separate from core_components to keep that module focused on
  UI primitives.
  """

  @doc """
  Format a duration in seconds as `M:SS` or `H:MM:SS`.
  """
  @spec duration_sec(number | nil) :: String.t()
  def duration_sec(nil), do: "—"

  def duration_sec(seconds) when is_number(seconds) do
    total = round(seconds)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)
    secs = rem(total, 60)

    cond do
      hours > 0 ->
        :io_lib.format("~b:~2..0b:~2..0b", [hours, minutes, secs]) |> IO.iodata_to_binary()

      true ->
        :io_lib.format("~b:~2..0b", [minutes, secs]) |> IO.iodata_to_binary()
    end
  end

  @doc """
  Human-readable label for a burpee_type enum.
  """
  @spec burpee_type(atom | String.t() | nil) :: String.t()
  def burpee_type(:six_count), do: "Six-count"
  def burpee_type(:navy_seal), do: "Navy SEAL"
  def burpee_type("six_count"), do: "Six-count"
  def burpee_type("navy_seal"), do: "Navy SEAL"
  def burpee_type(_), do: "—"

  @doc """
  Human-readable label for a level atom.
  """
  @spec level(atom) :: String.t()
  def level(:graduated), do: "Graduated"
  def level(:level_4), do: "Level 4"
  def level(:level_3), do: "Level 3"
  def level(:level_2), do: "Level 2"
  def level(:level_1d), do: "Level 1D"
  def level(:level_1c), do: "Level 1C"
  def level(:level_1b), do: "Level 1B"
  def level(:level_1a), do: "Level 1A"
  def level(_), do: "—"

  @doc "One line for a goal, the same on History and Coach: \"150 six-count burpees in 20 min by 9 Nov\", with the year only when it is not `today`'s."
  @spec goal(map(), Date.t()) :: String.t()
  def goal(
        %{
          burpee_type: type,
          burpee_count_target: reps,
          duration_sec_target: sec,
          date_target: date
        },
        today \\ Date.utc_today()
      ),
      do:
        "#{reps} #{goal_burpee(type)} burpees in #{div(sec, 60)} min by #{goal_date(date, today)}"

  defp goal_burpee(type) when type in [:six_count, "six_count"], do: "six-count"
  defp goal_burpee(type), do: burpee_type(type)

  @doc "A goal's what, without its date: \"150 six-count burpees in 20 min\"."
  @spec goal_title(map()) :: String.t()
  def goal_title(%{burpee_type: type, burpee_count_target: reps, duration_sec_target: sec}),
    do: "#{reps} #{goal_burpee(type)} burpees in #{div(sec, 60)} min"

  @doc "A goal's date: \"by 9 Nov\", with the year only when it is not `today`'s."
  @spec goal_by(map(), Date.t()) :: String.t()
  def goal_by(%{date_target: date}, today \\ Date.utc_today()), do: "by #{goal_date(date, today)}"

  defp goal_date(%Date{year: year} = date, %Date{year: year}),
    do: Calendar.strftime(date, "%-d %b")

  defp goal_date(%Date{} = date, _today), do: Calendar.strftime(date, "%-d %b %Y")

  @doc "A training week by its dates, Monday to Sunday: \"7–13 Sep\", \"28 Sep – 4 Oct\"."
  @spec week(Date.t()) :: String.t()
  def week(%Date{} = monday) do
    sunday = Date.add(monday, 6)
    week(monday, sunday, monday.month == sunday.month)
  end

  defp week(monday, sunday, true = _same_month?),
    do: "#{monday.day}–#{sunday.day} #{Calendar.strftime(sunday, "%b")}"

  defp week(monday, sunday, false),
    do: "#{Calendar.strftime(monday, "%-d %b")} – #{Calendar.strftime(sunday, "%-d %b")}"
end
