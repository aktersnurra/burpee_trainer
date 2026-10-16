defmodule BurpeeTrainer.Evals.ApprovalPreview do
  @moduledoc "Validate real approval and keyed replay without leaving an eval publication behind."
  alias BurpeeTrainer.{Coach, Repo}

  def validate(scope, prepared) do
    case Repo.immediate_transaction(fn ->
           with {:ok, plan} <- Coach.approve_plan(scope, prepared),
                {:ok, replay} <- Coach.approve_plan(scope, prepared),
                true <-
                  plan.id == replay.id and plan.state == :published and
                    plan.user_id == scope.user.id and plan.definition_json == prepared.definition do
             Repo.rollback(
               {:eval_approval_preview,
                %{approval_validated: true, publication_rolled_back: true}}
             )
           else
             {:error, reason} -> Repo.rollback({:eval_approval_failed, reason})
             _ -> Repo.rollback({:eval_approval_failed, :invalid_approval_replay})
           end
         end) do
      {:error, {:eval_approval_preview, facts}} -> {:ok, facts}
      {:error, {:eval_approval_failed, reason}} -> {:error, reason}
    end
  end
end
