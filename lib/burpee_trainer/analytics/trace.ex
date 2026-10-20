defmodule BurpeeTrainer.Analytics.Trace do
  @moduledoc "Sensitive owner-scoped seven-day traces, twenty per owner; no unscoped read API."
  import Ecto.Query
  alias BurpeeTrainer.{Accounts.Scope, Repo}
  alias BurpeeTrainer.Analytics.{Limits, TraceRecord}

  def store(%Scope{user: %{id: owner}}, id, payload, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    timeout = Keyword.get(opts, :timeout, 1000)

    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, json} <- Jason.encode(payload),
         true <- byte_size(json) <= Limits.trace_bytes() do
      persist(owner, id, json, now, timeout)
    else
      false -> {:error, :trace_too_large}
      _ -> {:error, :trace_unavailable}
    end
  rescue
    _error in [DBConnection.ConnectionError, Exqlite.Error, Ecto.ConstraintError] ->
      {:error, :trace_unavailable}
  end

  def fetch(%Scope{user: %{id: owner}}, id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        prune_owner(owner, now, 1000)

        case Repo.one(
               from(t in TraceRecord,
                 where: t.user_id == ^owner and t.id == ^id and t.expires_at > ^now
               ),
               timeout: 1000
             ) do
          nil -> {:error, :not_found}
          trace -> Jason.decode(trace.payload)
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp persist(owner, id, json, now, timeout) do
    result =
      Repo.immediate_transaction(
        fn ->
          prune_owner(owner, now, timeout)

          Repo.insert!(
            %TraceRecord{
              id: id,
              user_id: owner,
              payload: json,
              inserted_at: now,
              expires_at: DateTime.add(now, 7, :day)
            },
            timeout: timeout
          )

          prune_owner(owner, now, timeout)
        end,
        timeout: timeout
      )

    case result do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :trace_unavailable}
    end
  end

  @doc false
  def timeout(%Scope{user: %{id: owner}}, id, deadline) do
    remaining = max(1, deadline - System.monotonic_time(:millisecond))

    query =
      from(t in TraceRecord,
        where: t.user_id == ^owner and t.id == ^id and t.expires_at > ^DateTime.utc_now()
      )

    trace = Repo.one(query, timeout: max(1, div(remaining, 2)))

    timeout_trace(trace, owner, id, deadline)
  rescue
    _error in [DBConnection.ConnectionError, Exqlite.Error] ->
      {:error, BurpeeTrainer.Workouts.Error.new(:run_timeout)}
  end

  defp timeout_trace(nil, _, _, _), do: {:error, BurpeeTrainer.Workouts.Error.new(:run_timeout)}

  defp timeout_trace(trace, owner, id, deadline) do
    payload = Jason.decode!(trace.payload)

    final = %{
      "status" => "budget_exhausted",
      "interpretation" => payload["interpretation"] || "",
      "answer" => "Analysis deadline exhausted.",
      "findings" => [],
      "limitations" => ["Analysis deadline exhausted."]
    }

    evidence = payload["evidence"] || []
    output = Map.merge(final, %{"trace_id" => id, "evidence" => evidence})

    json =
      Jason.encode!(
        Map.put(payload, "final", Map.put(final, "evidence_ids", Enum.map(evidence, & &1["id"])))
      )

    with true <- byte_size(json) <= Limits.trace_bytes(),
         {:ok, output} <-
           BurpeeTrainer.Analytics.Output.validate(output, Enum.map(evidence, & &1["id"])),
         {1, _} <-
           Repo.update_all(
             from(t in TraceRecord, where: t.user_id == ^owner and t.id == ^id),
             [set: [payload: json]],
             timeout: max(1, deadline - System.monotonic_time(:millisecond))
           ) do
      {:ok, output}
    else
      _ -> {:error, BurpeeTrainer.Workouts.Error.new(:trace_unavailable)}
    end
  end

  @doc false
  def delete_expired do
    Repo.delete_all(from(t in TraceRecord, where: t.expires_at <= ^DateTime.utc_now()),
      timeout: 1000
    )

    :ok
  end

  defp prune_owner(owner, now, timeout) do
    owned = from(t in TraceRecord, where: t.user_id == ^owner)
    Repo.delete_all(from(t in owned, where: t.expires_at <= ^now), timeout: timeout)

    retained =
      Repo.all(
        from(t in owned, order_by: [desc: t.inserted_at, desc: t.id], limit: 20, select: t.id),
        timeout: timeout
      )

    Repo.delete_all(from(t in owned, where: t.id not in ^retained), timeout: timeout)
  end
end
