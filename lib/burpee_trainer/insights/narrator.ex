defmodule BurpeeTrainer.Insights.Narrator do
  @moduledoc "Short completed-session narration grounded exclusively in computed metrics."
  alias BurpeeTrainer.{Goals, Insights, UserTime, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{AuthoritativeSession, Client, Voice}
  alias BurpeeTrainer.Insights.{Metrics, Validator}
  alias BurpeeTrainer.Workouts.WorkoutSession

  @schema %{
    type: "object",
    additionalProperties: false,
    properties: %{
      headline: %{type: "string", minLength: 1, maxLength: 80},
      points: %{
        type: "array",
        maxItems: 3,
        items: %{
          type: "object",
          additionalProperties: false,
          properties: %{
            text: %{type: "string", maxLength: 160},
            metric_ids: %{type: "array", items: %{type: "string"}}
          },
          required: ["text", "metric_ids"]
        }
      }
    },
    required: ["headline", "points"]
  }

  def narrate(scope, session, opts \\ [])

  def narrate(%Scope{} = scope, %WorkoutSession{id: id}, opts) do
    case Workouts.get_session(scope, id) do
      %WorkoutSession{} = owned ->
        with true <- AuthoritativeSession.authoritative?(owned),
             {:ok, _} <- UserTime.context(scope.user, owned.completed_at) do
          case Insights.for_session(scope, id) do
            nil -> generate(scope, owned, opts)
            existing -> {:ok, existing}
          end
        else
          false -> {:error, :session_not_completed}
          error -> error
        end

      _ ->
        {:error, :session_not_owned}
    end
  end

  defp generate(scope, session, opts) do
    sessions = Workouts.list_sessions(scope)

    goals =
      for type <- [:six_count, :navy_seal],
          goal = Goals.get_active_goal(scope, type),
          not is_nil(goal),
          do: goal

    {:ok, metrics} = Metrics.for_session(scope, sessions, goals, session)

    messages = [
      %{
        role: "system",
        content:
          Voice.text() <>
            "\n" <>
            "Write one insight about the session they just finished: a short headline and up to three points, shown right after the session. Say what went well or what changed, plainly. No numbers in the headline. Every number in a point must be a value from the metrics below, and list each metric id you used in metric_ids. A level or status metric may be named, but it never supports a number. For a camera session, how they held the beat, the window left after each set (slack), where their pace faded and how they compare with the last time they did this workout matter more than totals; when session.camera_coverage_pct is there without session.kept_up, the camera missed the start, so say nothing about how the session went inside it. Metrics: " <>
            Jason.encode!(metrics)
      }
    ]

    chat_opts =
      opts
      |> Keyword.take([:config, :req, :budget])
      |> Keyword.merge(
        response_format: {"session_insight", @schema},
        ledger: %{scope: scope, purpose: "insight", run_id: Ecto.UUID.generate()}
      )

    {insight, source} =
      with {:ok, %{content: content, tool_calls: []}} <- Client.chat(messages, chat_opts),
           {:ok, validated} <- Validator.validate(content, metrics) do
        {validated, "llm"}
      else
        _ -> {fallback(metrics), "fallback"}
      end

    Insights.store(scope, session.id, insight, source)
  end

  def fallback(metrics) do
    week =
      case {metrics["week.minutes"], metrics["week.target_minutes"]} do
        {nil, _} ->
          []

        {minutes, nil} ->
          [point("#{Metrics.format(minutes)} minutes done this week.", ["week.minutes"])]

        {minutes, target} ->
          [
            point(
              "#{Metrics.format(minutes)} of #{Metrics.format(target)} minutes done this week.",
              ["week.minutes", "week.target_minutes"]
            )
          ]
      end

    session =
      case metrics["session.reps"] do
        nil -> []
        reps -> [point("#{Metrics.format(reps)} reps last session.", ["session.reps"])]
      end

    %{"headline" => "Session saved", "points" => week ++ session ++ camera(metrics)}
  end

  # The camera's view of the session, when it caught the start.
  defp camera(%{"same_workout.finish_change_sec" => %{value: change}}) when change != 0,
    do: [
      point(
        "Sets finished #{if change < 0, do: "faster", else: "slower"} than last time.",
        ["same_workout.finish_change_sec"]
      )
    ]

  defp camera(%{"session.kept_up" => %{value: "kept up"}}),
    do: [point("Held the beat to the end.", ["session.kept_up"])]

  defp camera(%{"session.kept_up" => %{value: "fell behind"}, "session.slip_at_min" => at}),
    do: [
      point("Fell behind the beat at minute #{Metrics.format(at)}.", [
        "session.kept_up",
        "session.slip_at_min"
      ])
    ]

  defp camera(_metrics), do: []

  defp point(text, ids), do: %{"text" => text, "metric_ids" => ids}
end
