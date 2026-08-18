defmodule BurpeeTrainer.Workouts.SessionLog do
  @moduledoc """
  Boundary helpers for free-form workout log params.

  LiveViews receive string-keyed params and a user's local date. This module
  validates that date before producing the historical `completed_at` fact.
  """

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.UserTime

  @form_string_fields ~w[
    burpee_count_actual
    duration_sec_actual
    note_pre
    note_post
    context_low_energy
    context_high_energy
    context_heat_affected
    primary_limiter
    preference_feedback
  ]

  @type attrs :: %{String.t() => term()}
  @type date_error :: :invalid_log_date | :future_log_date | :invalid_timezone

  @spec parse_log_date(map()) :: {:ok, Date.t()} | {:error, :invalid_log_date}
  def parse_log_date(params) when is_map(params) do
    case params["log_date"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _error -> {:error, :invalid_log_date}
        end

      _forged_or_missing ->
        {:error, :invalid_log_date}
    end
  end

  @doc false
  @spec parse_log_date(map(), Date.t()) :: {:ok, Date.t()} | {:error, :invalid_log_date}
  def parse_log_date(params, %Date{}), do: parse_log_date(params)

  @spec to_attrs(map(), atom(), integer(), [String.t()], User.t(), DateTime.t()) ::
          {:ok, attrs()} | {:error, date_error()}
  def to_attrs(params, burpee_type, mood, tags, %User{} = user, %DateTime{} = now)
      when is_map(params) and is_atom(burpee_type) and is_integer(mood) and is_list(tags) do
    with {:ok, log_date} <- parse_log_date(params),
         {:ok, context} <- UserTime.context(user, now),
         :ok <- validate_not_future(log_date, context.date),
         {:ok, completed_at} <- completed_at(log_date, context, now) do
      attrs =
        params
        |> normalize_form_params()
        |> Map.put("burpee_type", Atom.to_string(burpee_type))
        |> Map.put("mood", Integer.to_string(mood))
        |> Map.put("tags", tags |> Enum.sort() |> Enum.join(","))
        |> Map.put("duration_sec_actual", duration_seconds(params["duration_sec_actual"]))
        |> Map.put("completed_at", completed_at)

      {:ok, attrs}
    end
  end

  @doc false
  @spec normalize_form_params(map()) :: attrs()
  def normalize_form_params(params) when is_map(params) do
    Map.new(@form_string_fields, fn field ->
      value = Map.get(params, field, "")
      {field, if(is_binary(value), do: value, else: "")}
    end)
  end

  defp validate_not_future(log_date, today) do
    if Date.compare(log_date, today) == :gt,
      do: {:error, :future_log_date},
      else: :ok
  end

  defp completed_at(log_date, context, now) do
    local_time = context.now |> DateTime.to_time() |> Time.truncate(:second)

    with {:ok, local_datetime} <- UserTime.resolve_local(log_date, local_time, context.timezone),
         {:ok, utc_datetime} <- DateTime.shift_zone(local_datetime, "Etc/UTC") do
      if DateTime.compare(utc_datetime, now) == :gt,
        do: {:ok, DateTime.truncate(now, :second)},
        else: {:ok, DateTime.truncate(utc_datetime, :second)}
    else
      _error -> {:error, :invalid_timezone}
    end
  end

  defp duration_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {minutes, ""} -> Integer.to_string(minutes * 60)
      _error -> value
    end
  end

  defp duration_seconds(_forged_or_missing), do: ""
end
