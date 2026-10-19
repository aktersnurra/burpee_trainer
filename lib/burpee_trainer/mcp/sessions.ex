defmodule BurpeeTrainer.Mcp.Sessions do
  @moduledoc """
  History filters as Claude sends them, validated into what `Workouts.list_sessions_page/3`
  takes, and a session as Claude reads it. Dates are the athlete's local dates.
  """

  alias BurpeeTrainer.{History, UserTime}
  alias BurpeeTrainer.Coach.AuthoritativeSession
  alias BurpeeTrainer.Stats.Series
  alias BurpeeTrainer.Workouts.Fatigue

  @types %{"six_count" => :six_count, "navy_seal" => :navy_seal}
  @capture_modes %{"tracked" => :tracked, "timed" => :timed, "logged" => :logged}

  @filter_keys ~w[from to burpee_type workout tags capture_mode min_reps max_reps]

  def filter_schema do
    %{
      "from" => %{
        "type" => "string",
        "format" => "date",
        "description" => "First local date, inclusive (YYYY-MM-DD)."
      },
      "to" => %{
        "type" => "string",
        "format" => "date",
        "description" => "Last local date, inclusive (YYYY-MM-DD)."
      },
      "burpee_type" => %{"type" => "string", "enum" => Map.keys(@types)},
      "workout" => %{
        "description" => "A workout id, or part of its name.",
        "anyOf" => [
          %{"type" => "integer", "minimum" => 1},
          %{"type" => "string", "minLength" => 1}
        ]
      },
      "tags" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Sessions with any of these tags."
      },
      "capture_mode" => %{
        "type" => "string",
        "enum" => Map.keys(@capture_modes),
        "description" =>
          "tracked: counted by camera; timed: run with the timer; logged: entered by hand."
      },
      "min_reps" => %{"type" => "integer", "minimum" => 0},
      "max_reps" => %{"type" => "integer", "minimum" => 0}
    }
  end

  def filter_keys, do: @filter_keys

  @doc "Validates Claude's filters into `Workouts` filters, in the user's timezone."
  @spec filters(map(), map(), DateTime.t()) :: {:ok, map()} | {:error, String.t()}
  def filters(args, user, now) do
    with {:ok, context} <- context(user, now) do
      args
      |> Map.take(@filter_keys)
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case filter(key, value, context.timezone) do
          {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          :error -> {:halt, {:error, "invalid #{key}: #{inspect(value)}"}}
        end
      end)
    end
  end

  defp context(user, now) do
    case UserTime.context(user, now) do
      {:ok, context} -> {:ok, context}
      {:error, _} -> {:error, "the athlete's timezone is not known"}
    end
  end

  defp filter("from", value, tz), do: local_bound(value, 0, tz, :from)
  defp filter("to", value, tz), do: local_bound(value, 1, tz, :before)
  defp filter("burpee_type", value, _), do: lookup(@types, value, :burpee_type)
  defp filter("capture_mode", value, _), do: lookup(@capture_modes, value, :capture_mode)
  defp filter("workout", id, _) when is_integer(id) and id > 0, do: {:ok, :plan_id, id}

  defp filter("workout", name, _) when is_binary(name) do
    case name |> String.replace(["%", "_"], "") |> String.trim() do
      "" -> :error
      name -> {:ok, :name, name}
    end
  end

  defp filter("tags", [_ | _] = tags, _) do
    tags =
      tags
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(&1 |> String.trim() |> String.replace([" ", "%"], "")))

    if tags != [] and Enum.all?(tags, &(&1 != "")), do: {:ok, :tags, tags}, else: :error
  end

  defp filter(key, reps, _) when key in ~w[min_reps max_reps] and is_integer(reps) and reps >= 0,
    do: {:ok, String.to_existing_atom(key), reps}

  defp filter(_key, _value, _tz), do: :error

  defp lookup(map, value, key) do
    case Map.fetch(map, value) do
      {:ok, atom} -> {:ok, key, atom}
      :error -> :error
    end
  end

  defp local_bound(value, days_after, tz, key) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, at} <- UserTime.resolve_local(Date.add(date, days_after), ~T[00:00:00], tz),
         {:ok, utc} <- DateTime.shift_zone(at, "Etc/UTC") do
      {:ok, key, utc}
    else
      _ -> :error
    end
  end

  defp local_bound(_value, _days_after, _tz, _key), do: :error

  @doc "Only sessions the app counts as real: completed, from a plan, a video or a log."
  def authoritative(sessions), do: Enum.filter(sessions, &AuthoritativeSession.authoritative?/1)

  @doc "A session as Claude reads it."
  def encode(session, timezone) do
    reps = session.burpee_count_actual
    duration = session.duration_sec_actual
    measured? = is_integer(reps) and reps > 0 and is_integer(duration) and duration > 0

    %{
      "id" => session.id,
      "date" => local_date(session.completed_at, timezone),
      "completed_at" => DateTime.to_iso8601(session.completed_at),
      "burpee_type" => to_string(session.burpee_type),
      "workout" => session.display_name_snapshot,
      "workout_id" => session.plan_id,
      "capture_mode" => to_string(session.capture_mode),
      "reps" => reps,
      "reps_planned" => session.burpee_count_planned,
      "duration_sec" => duration,
      "duration_sec_planned" => session.duration_sec_planned,
      "minutes_counted" => div(History.credited_seconds(session), 60),
      "pace_sec" => if(measured?, do: Float.round(duration / reps, 2)),
      "reps_per_20_min" =>
        if(measured?, do: hd(Series.progress([session]).points).normalized_reps),
      "pace_consistency" => session.pace_consistency,
      "sets_completed" => session.prescribed_sets_completed,
      "fatigue" => Fatigue.summary(session),
      "mood" => session.mood,
      "primary_limiter" => session.primary_limiter && to_string(session.primary_limiter),
      "preference" => session.preference_feedback && to_string(session.preference_feedback),
      "low_energy" => session.context_low_energy,
      "high_energy" => session.context_high_energy,
      "heat_affected" => session.context_heat_affected,
      "tags" => tags(session.tags),
      "note_pre" => session.note_pre,
      "note_post" => session.note_post
    }
  end

  def tags(tags) when is_binary(tags),
    do:
      tags
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  def tags(_), do: []

  def local_date(%DateTime{} = at, timezone) do
    case UserTime.local_date(at, timezone) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> at |> DateTime.to_date() |> Date.to_iso8601()
    end
  end

  @doc "An opaque cursor for the `{completed_at, id}` after which the next page starts."
  def encode_cursor({%DateTime{} = at, id}),
    do: Base.url_encode64("#{DateTime.to_unix(at)}:#{id}", padding: false)

  def encode_cursor(_), do: nil

  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [unix, id] <- String.split(raw, ":"),
         {unix, ""} <- Integer.parse(unix),
         {id, ""} when id > 0 <- Integer.parse(id),
         {:ok, at} <- DateTime.from_unix(unix) do
      {:ok, {at, id}}
    else
      _ -> {:error, "invalid cursor"}
    end
  end

  def decode_cursor(_), do: {:error, "invalid cursor"}
end
