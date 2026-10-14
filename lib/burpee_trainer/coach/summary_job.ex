defmodule BurpeeTrainer.Coach.SummaryJob do
  @moduledoc """
  Regenerates the owner's two-sentence coach summary from computed metrics.

  One pending job per user: a trigger while a job is waiting is absorbed by it, while a
  running job never swallows a newer trigger.
  """
  use Oban.Worker,
    queue: :coach,
    max_attempts: 1,
    unique: [keys: [:user_id], period: :infinity, states: [:available, :scheduled]]

  require Logger

  alias BurpeeTrainer.{Accounts, Goals, Repo, UserTime, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Client, Summary, Voice}
  alias BurpeeTrainer.Insights.{Metrics, Validator}

  @schema %{
    type: "object",
    additionalProperties: false,
    properties: %{
      text: %{type: "string", minLength: 1, maxLength: 280},
      review: %{type: "string", maxLength: 280},
      metric_ids: %{type: "array", items: %{type: "string"}},
      replies: BurpeeTrainer.Coach.Suggestions.schema()
    },
    required: ["text", "review", "metric_ids", "replies"]
  }

  @spec enqueue(Scope.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%Scope{} = scope) do
    Repo.immediate_transaction(fn ->
      case admit(scope) do
        {:ok, job} -> job
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Admits the job inside the caller's transaction; a failure never rolls it back."
  @spec admit(Scope.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def admit(%Scope{user: user}), do: %{"user_id" => user.id} |> new() |> Oban.insert()

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) when is_integer(user_id) do
    case Accounts.get_user(user_id) do
      %Accounts.User{} = user ->
        scope = Scope.for_user(user)

        # Home shows a loader until it hears from this job, so it hears even when it raises.
        try do
          case summarize(scope) do
            {:ok, _summary} -> :ok
            :none -> :ok
            {:error, reason} -> {:error, reason}
          end
        after
          Summary.broadcast(scope, Summary.get(scope))
        end

      nil ->
        {:cancel, :user_missing}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  @type status :: :absent | :current | :stale

  @doc """
  How the stored summary stands at `now`: `:absent` with nothing to report, `:current`
  when written during the owner's current local week, `:stale` otherwise.
  """
  @spec status(Scope.t(), DateTime.t()) :: {status(), Summary.t() | nil}
  def status(%Scope{user: user} = scope, %DateTime{} = now) do
    reportable? = Workouts.completed_session?(scope) or Goals.any_active?(scope)

    with {:ok, context} <- UserTime.context(user, now),
         {:ok, week_start_utc, _week_end_utc} <- UserTime.week_bounds_utc(context) do
      summary = Summary.get(scope)
      {freshness(reportable?, summary, week_start_utc), summary}
    else
      _invalid_timezone -> {:absent, nil}
    end
    |> shown()
  end

  @doc "Opening the app refreshes a stale summary; `:refreshing` once a job is admitted."
  @spec on_open(Scope.t(), DateTime.t()) :: {status() | :refreshing, Summary.t() | nil}
  def on_open(%Scope{} = scope, %DateTime{} = now),
    do: scope |> status(now) |> refresh(scope)

  defp freshness(false = _reportable?, _summary, _week_start_utc), do: :absent
  defp freshness(true, nil = _summary, _week_start_utc), do: :stale

  defp freshness(true, %Summary{updated_at: written_at}, week_start_utc),
    do: written_in_week(DateTime.compare(written_at, week_start_utc))

  defp written_in_week(:lt), do: :stale
  defp written_in_week(_at_or_after_week_start), do: :current

  defp shown({:absent, _summary}), do: {:absent, nil}
  defp shown(status), do: status

  defp refresh({:stale, summary}, scope) do
    case enqueue(scope) do
      {:ok, _job} ->
        {:refreshing, summary}

      {:error, reason} ->
        Logger.warning(
          "coach_summary_not_admitted trigger=open user_id=#{scope.user.id} reason=#{inspect(reason)}"
        )

        {:stale, summary}
    end
  end

  defp refresh(status, _scope), do: status

  @doc "Stores a validated summary, or the metric fallback; `:none` with nothing to report."
  @spec summarize(Scope.t(), keyword()) :: {:ok, Summary.t()} | :none | {:error, term()}
  def summarize(%Scope{} = scope, opts \\ []) do
    {sessions, goals} = inputs(scope)
    generate(scope, sessions, goals, opts)
  end

  defp inputs(scope) do
    goals =
      for type <- [:six_count, :navy_seal],
          goal = Goals.get_active_goal(scope, type),
          not is_nil(goal),
          do: goal

    {Workouts.list_sessions(scope), goals}
  end

  defp generate(_scope, [] = _sessions, [] = _goals, _opts), do: :none

  defp generate(scope, sessions, goals, opts) do
    metrics = Metrics.for_scope(scope, sessions, goals, DateTime.utc_now())

    messages = [
      %{
        role: "system",
        content:
          Voice.text() <>
            "\n" <>
            "Write at most two sentences explaining what the rest of this week should aim for, given what is left of the weekly training window (week.minutes of week.target_minutes) and their active goal, or the next level when they have none. It sits under a list of this week's sessions done and left, and their goals are shown elsewhere, so do not restate their best or their target; use a number only when it says something the page does not. In review, write at most two sentences looking back over the last weeks for each burpee type: what is rising, what is flat, what was missed. It leads their Progress page, above each goal's best and target, so do not restate those either. In replies, give up to three short changes the athlete might ask for, in their own words (under 60 characters each). Every number must be a value from the metrics below, and list each metric id you used in metric_ids. Metrics: " <>
            Jason.encode!(metrics)
      }
    ]

    chat_opts =
      opts
      |> Keyword.take([:config, :req, :budget])
      |> Keyword.merge(
        response_format: {"coach_summary", @schema},
        ledger: %{scope: scope, purpose: "summary", run_id: Ecto.UUID.generate()}
      )

    with {:ok, %{content: content, tool_calls: []}} <- Client.chat(messages, chat_opts),
         {:ok, validated} <- Validator.validate_summary(content, metrics) do
      store(scope, Map.put(validated, "review", review(content, metrics)), :llm)
    else
      _ ->
        case fallback(metrics) do
          nil -> :none
          summary -> store(scope, summary, :fallback)
        end
    end
  end

  # The look back is checked like the note; one that fails is left out, not the note.
  defp review(%{"review" => review, "metric_ids" => ids}, metrics)
       when is_binary(review) and review != "" do
    case Validator.validate_summary(%{"text" => review, "metric_ids" => ids}, metrics) do
      {:ok, _} -> review
      {:error, _} -> nil
    end
  end

  defp review(_content, _metrics), do: nil

  defp store(scope, summary, source),
    do:
      Summary.store(scope, %{
        text: summary["text"],
        metric_ids: summary["metric_ids"],
        source: source,
        review: summary["review"],
        suggestions: BurpeeTrainer.Coach.Suggestions.clean(summary["replies"])
      })

  @doc """
  Deterministic summary from the same metrics: only a short last week, the one figure the
  Progress page does not already show (its headline has the goal, its record the week).
  `nil` when there is nothing to add.
  """
  @spec fallback(map()) :: %{String.t() => term()} | nil
  def fallback(metrics) do
    case shortfall(metrics) do
      nil -> nil
      {text, ids} -> %{"text" => text, "metric_ids" => ids}
    end
  end

  defp shortfall(%{
         "last_week.minutes" => %{value: minutes} = done,
         "last_week.target_minutes" => %{value: target} = goal
       })
       when minutes < target,
       do:
         {"Last week: #{Metrics.format(done)} of #{Metrics.format(goal)} minutes.",
          ["last_week.minutes", "last_week.target_minutes"]}

  defp shortfall(_metrics), do: nil
end
