defmodule BurpeeTrainer.Coach.Memory do
  import Ecto.Query
  alias BurpeeTrainer.{Accounts, Repo, Workouts}
  alias BurpeeTrainer.Coach.Context
  alias BurpeeTrainer.Coach.{Setting, WorkoutMemory}

  def global_context(user) do
    settings =
      case Repo.get_by(Setting, user_id: user.id) do
        nil -> %{}
        row -> row.settings
      end

    memories =
      Repo.all(
        from(m in WorkoutMemory,
          where: m.user_id == ^user.id,
          order_by: [asc: m.id]
        )
      )

    %{
      settings: settings,
      workout_memories:
        Enum.map(memories, fn m ->
          %{
            workout_plan_id: m.workout_plan_id,
            design_session_id: m.design_session_id,
            facts: m.facts,
            workout_reason: m.workout_reason
          }
        end)
    }
  end

  @spec record_finalized_workout(integer(), integer(), integer() | nil) :: :ok | {:error, term()}
  def record_finalized_workout(user_id, plan_id, design_session_id) do
    with %Accounts.User{} = user <- Accounts.get_user(user_id),
         %Workouts.WorkoutPlan{user_id: ^user_id, state: state} = plan <-
           Repo.get(Workouts.WorkoutPlan, plan_id),
         true <- state in [:published, :archived] and plan.design_session_id == design_session_id,
         {:ok, entries} <- memory_entries(user, design_session_id) do
      attempts =
        entries
        |> Enum.filter(fn e ->
          e.kind == :outcome and e.payload["status"] == "accepted" and
            (e.payload["workout_plan_id"] == plan.id or e.payload["pending_draft_id"] == plan.id)
        end)
        |> MapSet.new(& &1.attempt_id)

      instructions =
        entries
        |> Enum.filter(
          &(&1.kind == :instruction and
              MapSet.member?(attempts, &1.attempt_id))
        )
        |> Enum.map(& &1.payload["text"])

      row = %{
        user_id: user.id,
        workout_plan_id: plan.id,
        design_session_id: design_session_id,
        facts: %{
          burpee_type: Atom.to_string(plan.burpee_type),
          reps: plan.target_reps,
          duration_sec: plan.target_duration_sec,
          content_hash: plan.content_hash
        },
        workout_reason: %{
          scope: "workout",
          rationale: plan.definition_json["rationale"],
          accepted_instructions: instructions
        },
        inserted_at: DateTime.utc_now()
      }

      Repo.insert_all(WorkoutMemory, [row],
        on_conflict: :nothing,
        conflict_target: [:user_id, :workout_plan_id]
      )

      :ok
    else
      _ -> {:error, :unavailable_finalized_workout}
    end
  rescue
    _ -> {:error, :memory_unavailable}
  end

  defp memory_entries(_user, nil), do: {:ok, []}
  defp memory_entries(user, id), do: Context.entries(user, id)
end
