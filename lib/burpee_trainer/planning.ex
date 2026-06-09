defmodule BurpeeTrainer.Planning do
  @moduledoc """
  Public facade for solving workout planning goals.
  """

  alias BurpeeTrainer.Planning.{Compiler, Draft, DraftGenerator, DraftVerifier, Goal}

  @spec solve(map() | Goal.t()) :: {:ok, Draft.t()} | {:error, term()}
  def solve(%Goal{} = goal) do
    with {:ok, draft} <- DraftGenerator.generate(goal),
         :ok <- DraftVerifier.verify(draft) do
      {:ok, draft}
    end
  end

  def solve(attrs) when is_map(attrs) do
    with {:ok, goal} <- Goal.new(attrs) do
      solve(goal)
    end
  end

  @spec build_plan(map() | Goal.t(), keyword()) ::
          {:ok, BurpeeTrainer.Workouts.WorkoutPlan.t()} | {:error, term()}
  def build_plan(goal_or_attrs, opts \\ []) do
    with {:ok, draft} <- solve(goal_or_attrs),
         {:ok, plan} <- Compiler.to_workout_plan(draft, opts) do
      {:ok, plan}
    end
  end
end
