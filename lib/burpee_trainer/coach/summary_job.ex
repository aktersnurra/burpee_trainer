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
  alias BurpeeTrainer.Coach.{Client, Summary}
  alias BurpeeTrainer.Insights.{Metrics, Validator}

  @schema %{
    type: "object",
    additionalProperties: false,
    properties: %{
      text: %{type: "string", minLength: 1, maxLength: 280},
      metric_ids: %{type: "array", items: %{type: "string"}}
    },
    required: ["text", "metric_ids"]
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
    {sessions, goals} = inputs(scope)

    with {:ok, context} <- UserTime.context(user, now),
         {:ok, week_start_utc, _week_end_utc} <- UserTime.week_bounds_utc(context) do
      summary = Summary.get(scope)
      {freshness(sessions, goals, summary, week_start_utc), summary}
    else
      _invalid_timezone -> {:absent, nil}
    end
    |> shown()
  end

  @doc "Opening the app refreshes a stale summary; `:refreshing` once a job is admitted."
  @spec on_open(Scope.t(), DateTime.t()) :: {status() | :refreshing, Summary.t() | nil}
  def on_open(%Scope{} = scope, %DateTime{} = now),
    do: scope |> status(now) |> refresh(scope)

  defp freshness([] = _sessions, [] = _goals, _summary, _week_start_utc), do: :absent
  defp freshness(_sessions, _goals, nil = _summary, _week_start_utc), do: :stale

  defp freshness(_sessions, _goals, %Summary{updated_at: written_at}, week_start_utc),
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
          "At most two sentences on progress and trajectory toward the active goals, or toward the next level when no goal is active. Cite metric ids for every number. Use only these metrics: " <>
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

    {summary, source} =
      with {:ok, %{content: content, tool_calls: []}} <- Client.chat(messages, chat_opts),
           {:ok, validated} <- Validator.validate_summary(content, metrics) do
        {validated, :llm}
      else
        _ -> {fallback(metrics), :fallback}
      end

    Summary.store(scope, %{
      text: summary["text"],
      metric_ids: summary["metric_ids"],
      source: source
    })
  end

  @doc """
  Deterministic summary from the same metrics, in priority order: a short last week, the
  first goal's trajectory, this week. At most two sentences, every number a metric value.
  """
  @spec fallback(map()) :: %{String.t() => term()}
  def fallback(metrics) do
    sentences =
      [shortfall(metrics), goal_trajectory(metrics), this_week(metrics)]
      |> Enum.reject(&is_nil/1)
      |> Enum.take(2)

    %{
      "text" => Enum.map_join(sentences, " ", &elem(&1, 0)),
      "metric_ids" => Enum.flat_map(sentences, &elem(&1, 1))
    }
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

  defp goal_trajectory(metrics) do
    metrics
    |> Map.keys()
    |> Enum.flat_map(&goal_id/1)
    |> Enum.min(fn -> nil end)
    |> goal_sentence(metrics)
  end

  defp goal_id(key) do
    case Regex.run(~r/^goal\.(\d+)\.days_left$/, key) do
      [_, id] -> [String.to_integer(id)]
      nil -> []
    end
  end

  defp goal_sentence(nil, _metrics), do: nil

  defp goal_sentence(id, metrics) do
    ids = ["goal.#{id}.best_reps", "goal.#{id}.target_reps", "goal.#{id}.days_left"]
    [best, target, days] = Enum.map(ids, &Metrics.format(Map.fetch!(metrics, &1)))
    {"Best so far #{best} of #{target} reps with #{days} days left.", ids}
  end

  defp this_week(%{"week.minutes" => done, "week.target_minutes" => goal}),
    do:
      {"#{Metrics.format(done)} of #{Metrics.format(goal)} minutes this week.",
       ["week.minutes", "week.target_minutes"]}

  defp this_week(_metrics), do: nil
end
