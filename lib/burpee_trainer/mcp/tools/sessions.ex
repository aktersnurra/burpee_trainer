defmodule BurpeeTrainer.Mcp.Tools.SessionFeedback do
  @moduledoc false
  # The athlete's feedback on a session, in the names Claude sends, and its checks.

  @limiters ~w[breathing whole_body upper_body legs]
  @preferences ~w[choose_again avoid]

  def schema,
    do: %{
      "note_pre" => %{"type" => "string", "description" => "What the athlete said before."},
      "note_post" => %{"type" => "string", "description" => "What the athlete said after."},
      "mood" => %{
        "type" => "integer",
        "enum" => [-1, 0, 1],
        "description" => "-1 rough, 0 fine, 1 good."
      },
      "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
      "primary_limiter" => %{
        "type" => "string",
        "enum" => @limiters,
        "description" => "What gave out first."
      },
      "preference" => %{
        "type" => "string",
        "enum" => @preferences,
        "description" => "Whether the athlete would choose this workout again."
      },
      "low_energy" => %{"type" => "boolean"},
      "high_energy" => %{"type" => "boolean"},
      "heat_affected" => %{"type" => "boolean"}
    }

  def keys, do: Map.keys(schema())

  @fields %{
    "note_pre" => "note_pre",
    "note_post" => "note_post",
    "mood" => "mood",
    "primary_limiter" => "primary_limiter",
    "preference" => "preference_feedback",
    "low_energy" => "context_low_energy",
    "high_energy" => "context_high_energy",
    "heat_affected" => "context_heat_affected"
  }

  @doc "Session attributes from Claude's feedback fields."
  def attrs(args) do
    Enum.reduce_while(Map.take(args, keys()), {:ok, %{}}, fn
      {"tags", tags}, {:ok, acc} ->
        case tags(tags) do
          {:ok, joined} -> {:cont, {:ok, Map.put(acc, "tags", joined)}}
          :error -> {:halt, {:error, "tags are words or short phrases without commas"}}
        end

      {"primary_limiter", value}, {:ok, _acc} when value not in @limiters and not is_nil(value) ->
        {:halt, {:error, "primary_limiter is one of #{Enum.join(@limiters, ", ")}"}}

      {"preference", value}, {:ok, _acc} when value not in @preferences and not is_nil(value) ->
        {:halt, {:error, "preference is one of #{Enum.join(@preferences, ", ")}"}}

      {key, value}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, Map.fetch!(@fields, key), value)}}
    end)
  end

  defp tags([]), do: {:ok, nil}

  defp tags(tags) when is_list(tags) do
    if Enum.all?(
         tags,
         &(is_binary(&1) and String.trim(&1) != "" and not String.contains?(&1, ","))
       ),
       do: {:ok, Enum.map_join(tags, ",", &String.trim/1)},
       else: :error
  end

  defp tags(_), do: :error

  def errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end

defmodule BurpeeTrainer.Mcp.Tools.LogSession do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.{UserTime, Workouts}
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.Sessions
  alias BurpeeTrainer.Mcp.Tools.SessionFeedback

  def name, do: "log_session"

  def description,
    do:
      "Log a session the athlete did away from the phone. It counts toward the week and " <>
        "the levels like any other session. date is the athlete's local date (today when " <>
        "left out) and time its local time (HH:MM). Reps and time cannot be changed later; " <>
        "feedback can, with edit_session."

  def schema,
    do:
      Tool.object(
        Map.merge(SessionFeedback.schema(), %{
          "burpee_type" => %{"type" => "string", "enum" => ~w[six_count navy_seal]},
          "reps" => %{"type" => "integer", "minimum" => 1},
          "duration_sec" => %{"type" => "integer", "minimum" => 1},
          "date" => %{"type" => "string", "format" => "date"},
          "time" => %{"type" => "string", "description" => "HH:MM, local."}
        }),
        ~w[burpee_type reps duration_sec]
      )

  @keys ~w[burpee_type reps duration_sec date time]

  def call(
        %{user: user} = scope,
        %{"burpee_type" => type, "reps" => reps, "duration_sec" => sec} = args,
        _
      )
      when type in ~w[six_count navy_seal] do
    now = DateTime.utc_now(:second)

    with [] <- Map.keys(args) -- (@keys ++ SessionFeedback.keys()),
         {:ok, completed_at} <- completed_at(args, user, now),
         {:ok, feedback} <- SessionFeedback.attrs(args),
         attrs =
           Map.merge(feedback, %{
             "burpee_type" => type,
             "burpee_count_actual" => reps,
             "duration_sec_actual" => sec
           }),
         {:ok, session} <- Workouts.log_session(scope, attrs, completed_at) do
      {:ok, %{"session" => Sessions.encode(session, user.timezone)}}
    else
      [_ | _] = unknown -> {:error, "unknown fields: #{Enum.join(unknown, ", ")}"}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, SessionFeedback.errors(changeset)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "the session could not be logged; nothing was saved"}
    end
  end

  def call(_, _, _),
    do: {:error, "log_session takes burpee_type (six_count or navy_seal), reps and duration_sec"}

  defp completed_at(args, user, now) do
    with {:ok, context} <- UserTime.context(user, now),
         {:ok, date} <- date(args["date"], context.date),
         {:ok, time} <- time(args["time"], date == context.date, context.now),
         {:ok, local} <- UserTime.resolve_local(date, time, context.timezone),
         {:ok, at} <- DateTime.shift_zone(local, "Etc/UTC") do
      if DateTime.compare(at, now) == :gt,
        do: {:error, "a session cannot be in the future"},
        else: {:ok, at}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "the athlete's timezone is not known"}
    end
  end

  defp date(nil, today), do: {:ok, today}

  defp date(value, _today) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "date must be YYYY-MM-DD"}
    end
  end

  defp date(_, _), do: {:error, "date must be YYYY-MM-DD"}

  # Without a time, today's session is now and an earlier day's is at noon.
  defp time(nil, true, local_now),
    do: {:ok, local_now |> DateTime.to_time() |> Time.truncate(:second)}

  defp time(nil, false, _local_now), do: {:ok, ~T[12:00:00]}

  defp time(value, _today?, _local_now) when is_binary(value) do
    case Time.from_iso8601(value <> ":00") do
      {:ok, time} -> {:ok, time}
      _ -> {:error, "time must be HH:MM"}
    end
  end

  defp time(_, _, _), do: {:error, "time must be HH:MM"}
end

defmodule BurpeeTrainer.Mcp.Tools.EditSession do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.Sessions
  alias BurpeeTrainer.Mcp.Tools.SessionFeedback
  alias BurpeeTrainer.Workouts

  def name, do: "edit_session"

  def description,
    do:
      "Correct the athlete's feedback on a session: notes, tags, mood, limiter, " <>
        "preference, energy and heat. A session's reps, time and date are its record and " <>
        "never change; to fix those, delete it and log it again."

  def schema,
    do:
      Tool.object(
        Map.put(SessionFeedback.schema(), "id", %{"type" => "integer", "minimum" => 1}),
        ["id"]
      )

  def call(%{user: user} = scope, %{"id" => id} = args, _) when is_integer(id) do
    with [] <- Map.keys(args) -- ["id" | SessionFeedback.keys()],
         {:ok, attrs} <- SessionFeedback.attrs(args),
         {:ok, session} <- Workouts.correct_session_feedback(scope, id, attrs) do
      {:ok, %{"session" => Sessions.encode(session, user.timezone)}}
    else
      [_ | _] = fields ->
        {:error,
         "only feedback can be corrected, not #{Enum.join(fields, ", ")}; to fix a result, delete the session and log it again"}

      {:error, :not_found} ->
        {:error, "no session #{id} of the athlete's"}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, SessionFeedback.errors(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  def call(_, _, _), do: {:error, "edit_session needs the session's id"}
end

defmodule BurpeeTrainer.Mcp.Tools.DeleteSession do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{SummaryJob, Tool}
  alias BurpeeTrainer.Workouts

  require Logger

  def name, do: "delete_session"

  def description,
    do:
      "Delete one of the athlete's sessions for good; it no longer counts toward the week " <>
        "or the levels."

  def schema, do: Tool.object(%{"id" => %{"type" => "integer", "minimum" => 1}}, ["id"])

  def call(scope, %{"id" => id} = args, _) when is_integer(id) and map_size(args) == 1 do
    case Workouts.delete_session(scope, id) do
      {:ok, _deleted} ->
        with {:error, reason} <- SummaryJob.admit(scope) do
          Logger.warning("coach_summary_not_admitted trigger=delete reason=#{inspect(reason)}")
        end

        {:ok, %{"deleted" => id}}

      {:error, _} ->
        {:error, "no session #{id} of the athlete's"}
    end
  end

  def call(_, _, _), do: {:error, "delete_session takes a session id"}
end
