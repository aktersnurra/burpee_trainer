defmodule BurpeeTrainer.Coach.Ledger do
  @moduledoc """
  Scoped rolling-24-hour budgets. Reservations serialize admission before network I/O. No
  bodies are stored.

  Calls the app makes on its own (`@automated`) and calls the owner starts are counted in
  separate buckets, so a long chat never leaves the overnight planner without budget.
  """
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Accounts.Scope}
  alias BurpeeTrainer.Coach.LlmCall

  @automated ~w(plan_next summary memory insight)
  @default_caps %{automated: 25, user: 40}

  @doc "The budget bucket a call's purpose counts against."
  @spec bucket(String.t()) :: :automated | :user
  def bucket(purpose) when purpose in @automated, do: :automated
  def bucket(_purpose), do: :user

  @doc "Admit one call before transport. Optional run_cap counts every owned run reservation, not just successful calls. Caller caps may tighten, never relax application daily policy."
  @spec reserve(Scope.t(), map(), keyword()) ::
          {:ok, LlmCall.t()} | {:error, :llm_budget_exhausted}
  def reserve(%Scope{user: %{id: id}} = scope, attrs, opts \\ []) do
    config = Application.get_env(:burpee_trainer, :llm_budget, [])
    opts = Keyword.merge(config, opts)
    bucket = bucket(Map.fetch!(attrs, :purpose))
    configured = Keyword.get(config, :"#{bucket}_daily_cap", @default_caps[bucket])
    cap = min(configured, Keyword.get(opts, :daily_cap, configured))
    run_cap = Keyword.get(opts, :run_cap)
    run_id = Map.fetch!(attrs, :run_id)

    cost_cap =
      [Keyword.get(config, :daily_cost_cap_usd), Keyword.get(opts, :daily_cost_cap_usd)]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    estimate =
      max(
        Keyword.get(config, :reservation_cost_usd, 0.0),
        Keyword.get(opts, :reservation_cost_usd, 0.0)
      )

    Repo.immediate_transaction(fn ->
      spent =
        Repo.one(
          from c in window(scope),
            select:
              coalesce(sum(fragment("COALESCE(?, ?)", c.cost_usd, c.reserved_cost_usd)), 0.0)
        )

      run_calls = Repo.aggregate(from(c in owned(scope), where: c.run_id == ^run_id), :count)

      if calls_today(scope, bucket) >= cap or (run_cap != nil and run_calls >= run_cap) or
           (cost_cap != nil and spent + estimate > cost_cap) do
        Repo.rollback(:llm_budget_exhausted)
      end

      %LlmCall{
        user_id: id,
        inserted_at: DateTime.utc_now(),
        outcome: "inflight",
        reserved_cost_usd: estimate
      }
      |> Ecto.Changeset.cast(attrs, [:purpose, :run_id, :model])
      |> Ecto.Changeset.validate_required([:purpose, :run_id, :model])
      |> Repo.insert!()
    end)
  end

  @spec finish(Scope.t(), pos_integer(), map()) :: :ok | {:error, :not_found}
  def finish(%Scope{} = scope, id, attrs) do
    attrs =
      Map.take(attrs, [:prompt_tokens, :completion_tokens, :cost_usd, :outcome, :duration_ms])

    {count, _} =
      Repo.update_all(from(c in owned(scope), where: c.id == ^id and c.outcome == "inflight"),
        set: Map.to_list(attrs)
      )

    if count == 1, do: :ok, else: {:error, :not_found}
  end

  defp calls_today(scope, :automated),
    do: Repo.aggregate(from(c in window(scope), where: c.purpose in @automated), :count)

  defp calls_today(scope, :user),
    do: Repo.aggregate(from(c in window(scope), where: c.purpose not in @automated), :count)

  defp owned(%Scope{user: %{id: id}}), do: from(c in LlmCall, where: c.user_id == ^id)

  defp window(scope) do
    since = DateTime.add(DateTime.utc_now(), -24, :hour)
    from c in owned(scope), where: c.inserted_at >= ^since
  end
end
