defmodule BurpeeTrainer.Coach.Ledger do
  @moduledoc "Scoped rolling-24-hour budgets. Reservations serialize admission before network I/O. No bodies are stored."
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Accounts.Scope}
  alias BurpeeTrainer.Coach.LlmCall

  @spec calls_today(Scope.t()) :: non_neg_integer()
  def calls_today(%Scope{} = scope), do: Repo.aggregate(window(scope), :count)

  @spec check_budget(Scope.t(), non_neg_integer()) :: :ok | {:error, :llm_budget_exhausted}
  def check_budget(%Scope{} = scope, cap \\ 40) do
    if calls_today(scope) < cap, do: :ok, else: {:error, :llm_budget_exhausted}
  end

  @doc "Admit one call before transport. Optional run_cap counts every owned run reservation, not just successful calls. Caller caps may tighten, never relax application daily policy."
  @spec reserve(Scope.t(), map(), keyword()) ::
          {:ok, LlmCall.t()} | {:error, :llm_budget_exhausted}
  def reserve(%Scope{user: %{id: id}} = scope, attrs, opts \\ []) do
    config = Application.get_env(:burpee_trainer, :llm_budget, [])
    opts = Keyword.merge(config, opts)
    cap = min(Keyword.get(config, :daily_cap, 40), Keyword.get(opts, :daily_cap, 40))
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

      if calls_today(scope) >= cap or (run_cap != nil and run_calls >= run_cap) or
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

  @spec record(Scope.t(), map()) :: :ok
  def record(%Scope{user: %{id: id}}, attrs) do
    %LlmCall{user_id: id, inserted_at: DateTime.utc_now()}
    |> Ecto.Changeset.cast(attrs, [
      :purpose,
      :run_id,
      :model,
      :prompt_tokens,
      :completion_tokens,
      :cost_usd,
      :outcome,
      :duration_ms
    ])
    |> Ecto.Changeset.validate_required([:purpose, :run_id, :model, :outcome, :duration_ms])
    |> Repo.insert!()

    :ok
  end

  defp owned(%Scope{user: %{id: id}}), do: from(c in LlmCall, where: c.user_id == ^id)

  defp window(scope) do
    since = DateTime.add(DateTime.utc_now(), -24, :hour)
    from c in owned(scope), where: c.inserted_at >= ^since
  end
end
