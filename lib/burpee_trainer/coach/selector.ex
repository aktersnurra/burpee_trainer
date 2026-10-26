defmodule BurpeeTrainer.Coach.Selector do
  @moduledoc """
  Plans a slot with a decision model first. It picks one of the saved or built-in workouts
  that fit the slot, or answers that none suits today, and the coach then designs one with
  `propose_workout` only. Without a decision model, when it fails, or when it is unsure, the
  full planner runs.
  A chosen workout gets the deterministic progression explanation, since the decision model writes no text.
  """

  alias BurpeeTrainer.Accounts.Scope

  alias BurpeeTrainer.Coach.{
    Agent,
    AgentPrompt,
    Client,
    Progression,
    RepCeiling,
    WorkoutPreference
  }

  alias BurpeeTrainer.Workouts

  require Logger

  @create "create_new"
  @default_min_confidence 0.6
  # A Choice question takes at most 255 options; one is `create_new`.
  @max_candidates 254

  @doc """
  Plans `slot`. `opts` pass to `Agent.run/4`, except `:decisions`: the `:config`, `:req` and
  `:budget` for the decision call.
  """
  @spec plan(Scope.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(%Scope{} = scope, slot, opts \\ []) do
    {decision_opts, agent_opts} = Keyword.pop(opts, :decisions, [])
    agent_opts = Keyword.put(agent_opts, :slot, slot)

    config =
      Keyword.get(decision_opts, :config, Application.get_env(:burpee_trainer, :decisions, []))

    if Keyword.get(config, :enabled, false) === true do
      # Read before the decision call, so a choice the owner or Claude makes while it is out
      # changes the selection and is kept.
      with {:ok, expected} <- Workouts.ensure_home_selection(scope, slot) do
        decided(scope, slot, expected, decide(scope, slot, config, decision_opts), agent_opts)
      end
    else
      Agent.run(scope, :planner, nil, agent_opts)
    end
  end

  defp decided(scope, _slot, expected, {:select, plan}, _agent_opts),
    do: select(scope, expected, plan)

  defp decided(scope, _slot, _expected, :create, agent_opts),
    do: Agent.run(scope, :planner, nil, Keyword.put(agent_opts, :create_only, true))

  defp decided(scope, _slot, _expected, :unavailable, agent_opts),
    do: Agent.run(scope, :planner, nil, agent_opts)

  defp decide(scope, slot, config, opts) do
    context = AgentPrompt.context(scope, slot)
    candidates = candidates(scope, slot)

    if candidates == [] do
      log(scope, @create, nil, %{})
      :create
    else
      result =
        Client.decide(
          context,
          %{"workout" => question(candidates, WorkoutPreference.for_scope(scope))},
          config: config,
          req: Keyword.get(opts, :req),
          budget: Keyword.get(opts, :budget, []),
          ledger: %{scope: scope, purpose: "select", run_id: Ecto.UUID.generate()}
        )

      case result do
        {:ok, %{answers: %{"workout" => %{"choice" => choice} = answer}}} ->
          log(scope, choice, answer["confidence"], answer["probabilities"])
          verdict(choice, answer["confidence"], candidates, config)

        {:ok, _unexpected} ->
          Logger.warning("coach_selection_unavailable user_id=#{scope.user.id} reason=no_answer")
          :unavailable

        {:error, error} ->
          Logger.warning(
            "coach_selection_unavailable user_id=#{scope.user.id} reason=#{inspect(Map.get(error, :code, error))}"
          )

          :unavailable
      end
    end
  end

  # An unsure answer, for a workout or for create_new, leaves the choice to the full planner.
  defp verdict(choice, confidence, candidates, config) do
    sure? =
      is_number(confidence) and
        confidence >= Keyword.get(config, :min_confidence, @default_min_confidence)

    case {sure?, choice, Enum.find(candidates, &(option(&1) == choice))} do
      {true, @create, _} -> :create
      {true, _choice, %{} = plan} -> {:select, plan}
      _unsure_or_unknown -> :unavailable
    end
  end

  defp select(scope, expected, plan) do
    rationale = scope |> Progression.for_type(plan.burpee_type) |> Progression.explanation()

    with {:ok, selection} <-
           Workouts.select_planned_workout(scope, expected, {:plan, plan.id}, rationale) do
      {:ok, %{reply: rationale, selection: selection}}
    end
  end

  # Fitting workouts: the slot's burpee type and minutes, within the same ceiling the coach's
  # own designs must keep (`RepCeiling`), and not one the athlete asked to avoid.
  defp candidates(scope, slot) do
    decision = Progression.for_type(scope, slot.burpee_type)
    preferences = WorkoutPreference.for_scope(scope)

    case RepCeiling.for_type(scope, slot.burpee_type) do
      {:ok, ceiling} ->
        scope
        |> Workouts.list_library()
        |> Enum.filter(fn plan ->
          Map.get(preferences, plan.id) != :avoid and plan.burpee_type == slot.burpee_type and
            plan.target_duration_sec == slot.duration_sec and
            RepCeiling.allows?(
              ceiling,
              plan.burpee_type,
              plan.target_reps,
              plan.target_duration_sec
            ) and Progression.allows?(decision, plan.target_reps, plan.target_duration_sec)
        end)
        |> Enum.take(@max_candidates)

      {:error, :timezone_unavailable} ->
        []
    end
  end

  defp reps_per_20(plan), do: RepCeiling.pace(plan.target_reps, plan.target_duration_sec)

  defp question(candidates, preferences) do
    %{
      "type" => "choice",
      "instructions" =>
        "Choose the athlete's next session from their saved and built-in workouts, given " <>
          "their recent sessions, feedback, goals and level. " <>
          AgentPrompt.progression_guidance() <>
          " Choose create_new when none fits the appropriate progression or recovery. " <>
          "A saved workout is not preferable merely because it already exists.",
      "criteria" =>
        candidates
        |> Map.new(fn plan ->
          {option(plan),
           %{
             "name" => plan.name,
             "reps" => plan.target_reps,
             "minutes" => div(plan.target_duration_sec, 60),
             "reps_per_20_minutes" => reps_per_20(plan),
             "saved_by" => if(plan.origin == :built_in, do: "app", else: "athlete")
           }
           |> put_wants_again(Map.get(preferences, plan.id))}
        end)
        |> Map.put(@create, "None of these suits the athlete today; design a new workout.")
    }
  end

  defp put_wants_again(criteria, :choose_again),
    do: Map.put(criteria, "athlete_feedback", "wants to do it again")

  defp put_wants_again(criteria, _), do: criteria

  defp option(plan), do: "workout_#{plan.id}"

  # Probabilities are logged so the confidence threshold can be tuned from real decisions.
  defp log(scope, choice, confidence, probabilities) do
    Logger.info(
      "coach_selection_decided user_id=#{scope.user.id} choice=#{choice} " <>
        "confidence=#{inspect(confidence)} probabilities=#{Jason.encode!(probabilities || %{})}"
    )
  end
end
