defmodule BurpeeTrainer.UserTime do
  @moduledoc false

  @type context :: %{
          now: DateTime.t(),
          date: Date.t(),
          week_start: Date.t(),
          timezone: String.t()
        }

  @spec context(%{timezone: String.t()}, DateTime.t()) ::
          {:ok, context()} | {:error, :invalid_timezone}
  def context(%{timezone: timezone}, %DateTime{} = now) when is_binary(timezone) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, local_now} ->
        date = DateTime.to_date(local_now)

        {:ok,
         %{
           now: local_now,
           date: date,
           week_start: Date.beginning_of_week(date, :monday),
           timezone: timezone
         }}

      {:error, _reason} ->
        {:error, :invalid_timezone}
    end
  end

  @spec resolve_local(Date.t(), Time.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, :invalid_timezone}
  def resolve_local(%Date{} = date, %Time{} = time, timezone) when is_binary(timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, after_gap} -> {:ok, after_gap}
      {:error, _reason} -> {:error, :invalid_timezone}
    end
  end

  @spec week_bounds_utc(context()) ::
          {:ok, DateTime.t(), DateTime.t()} | {:error, :invalid_timezone}
  def week_bounds_utc(%{week_start: week_start, timezone: timezone}) do
    with {:ok, local_start} <- local_midnight(week_start, timezone),
         {:ok, local_end} <- local_midnight(Date.add(week_start, 7), timezone),
         {:ok, utc_start} <- DateTime.shift_zone(local_start, "Etc/UTC"),
         {:ok, utc_end} <- DateTime.shift_zone(local_end, "Etc/UTC") do
      {:ok, utc_start, utc_end}
    else
      _error -> {:error, :invalid_timezone}
    end
  end

  @spec in_week?(DateTime.t() | NaiveDateTime.t() | Date.t(), Date.t(), String.t()) :: boolean()
  def in_week?(inserted_at, %Date{} = week_start, timezone) when is_binary(timezone) do
    week_end = Date.add(week_start, 7)

    case local_date(inserted_at, timezone) do
      {:ok, date} ->
        Date.compare(date, week_start) != :lt and Date.compare(date, week_end) == :lt

      {:error, _reason} ->
        false
    end
  end

  @spec local_date(DateTime.t() | NaiveDateTime.t() | Date.t(), String.t()) ::
          {:ok, Date.t()} | {:error, :invalid_timezone | :invalid_timestamp}
  def local_date(%DateTime{} = inserted_at, timezone) do
    case DateTime.shift_zone(inserted_at, timezone) do
      {:ok, local_datetime} -> {:ok, DateTime.to_date(local_datetime)}
      {:error, _reason} -> {:error, :invalid_timezone}
    end
  end

  def local_date(%NaiveDateTime{} = inserted_at, _timezone),
    do: {:ok, NaiveDateTime.to_date(inserted_at)}

  def local_date(%Date{} = inserted_at, _timezone), do: {:ok, inserted_at}
  def local_date(_inserted_at, _timezone), do: {:error, :invalid_timestamp}

  defp local_midnight(date, timezone), do: resolve_local(date, ~T[00:00:00], timezone)
end
