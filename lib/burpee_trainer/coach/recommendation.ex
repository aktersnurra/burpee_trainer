defmodule BurpeeTrainer.Coach.Recommendation do
  @moduledoc "Strict provider proposal boundary for coach recommendations."

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.{PlanCompiler, Repo}
  alias BurpeeTrainer.PlanCompiler.{ProgramHash, WorkoutDefinition}
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Error, WorkoutPlan}

  @type proposal ::
          {:select_existing, pos_integer(), String.t()}
          | {:create, map(), String.t()}

  @spec parse_proposal(map()) :: {:ok, proposal()} | {:error, Error.t()}
  def parse_proposal(%{
        "action" => "select_existing",
        "workout_plan_id" => plan_id,
        "rationale" => rationale
      })
      when is_integer(plan_id) and plan_id > 0 and is_binary(rationale) and rationale != "" do
    {:ok, {:select_existing, plan_id, rationale}}
  end

  def parse_proposal(%{
        "action" => "create",
        "definition" => definition,
        "rationale" => rationale
      })
      when is_map(definition) and is_binary(rationale) and rationale != "" do
    with {:ok, parsed} <- WorkoutDefinition.new(definition),
         {:ok, _program} <- PlanCompiler.compile(parsed) do
      {:ok, {:create, WorkoutDefinition.canonical_map(parsed), rationale}}
    else
      _invalid -> invalid_provider_response()
    end
  end

  def parse_proposal(_unknown), do: invalid_provider_response()

  @spec apply_proposal(User.t(), pos_integer(), map()) ::
          {:ok, CoachRecommendation.t()} | {:error, Error.t()}
  def apply_proposal(%User{} = user, recommendation_id, response) do
    apply_proposal(user, recommendation_id, response, :any)
  end

  @spec apply_proposal(User.t(), pos_integer(), map(), CoachRecommendation.selection() | :any) ::
          {:ok, CoachRecommendation.t()} | {:error, Error.t()}
  def apply_proposal(%User{} = user, recommendation_id, response, expected_selection)
      when is_integer(recommendation_id) and recommendation_id > 0 and is_map(response) do
    with {:ok, proposal} <- parse_proposal(response),
         :ok <- verify_slot_policy(user, recommendation_id, proposal) do
      apply_verified_proposal(user, recommendation_id, proposal, expected_selection)
    end
  end

  def apply_proposal(%User{}, _recommendation_id, response, _expected_selection)
      when is_map(response) do
    with {:ok, _proposal} <- parse_proposal(response) do
      invalid_provider_response()
    end
  end

  def apply_proposal(%User{}, _recommendation_id, _response, _expected_selection),
    do: invalid_provider_response()

  defp verify_slot_policy(%User{id: user_id} = user, recommendation_id, proposal) do
    with %CoachRecommendation{slot_date: %Date{} = slot_date} <-
           Repo.get_by(CoachRecommendation, id: recommendation_id, user_id: user_id),
         {:ok, candidate} <- proposal_candidate(user, proposal),
         :ok <- Policy.verify_candidate(user, slot_date, candidate) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      _missing_or_invalid -> invalid_selection()
    end
  end

  defp proposal_candidate(user, {:select_existing, plan_id, _rationale}) do
    case Workouts.get_library_plan(user, plan_id) do
      {:ok, %WorkoutPlan{} = plan} -> {:ok, plan}
      {:error, %Error{}} -> invalid_selection()
    end
  end

  defp proposal_candidate(_user, {:create, definition, _rationale}) do
    with {:ok, parsed} <- WorkoutDefinition.new(definition),
         {:ok, program} <- PlanCompiler.compile(parsed) do
      {:ok,
       %WorkoutPlan{
         name: parsed.name,
         state: :draft,
         origin: :coach,
         definition_json: definition,
         program_json: ProgramHash.canonical_map(program),
         burpee_type: parsed.burpee_type,
         target_reps: parsed.target_reps,
         target_duration_sec: parsed.target_duration_sec
       }}
    else
      _invalid -> invalid_selection()
    end
  end

  defp apply_verified_proposal(
         user,
         recommendation_id,
         {:select_existing, plan_id, rationale},
         expected_selection
       ) do
    Workouts.select_recommendation_candidate_if_current(
      user,
      recommendation_id,
      plan_id,
      rationale,
      expected_selection
    )
  end

  defp apply_verified_proposal(
         user,
         recommendation_id,
         {:create, definition, rationale},
         expected_selection
       ) do
    Workouts.attach_candidate_if_current(
      user,
      recommendation_id,
      %{
        definition: definition,
        request_text: rationale,
        rationale: rationale
      },
      expected_selection
    )
  end

  defp invalid_selection,
    do: {:error, Error.new(:invalid_recommendation_selection, %{reason: :policy_mismatch})}

  defp invalid_provider_response,
    do: {:error, Error.new(:invalid_provider_response)}
end
