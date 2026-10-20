defmodule BurpeeTrainer.Analytics.Analyst do
  @moduledoc "Serial bounded single-action analyst, with code-owned successful evidence."
  alias BurpeeTrainer.Analytics.{
    CallBudget,
    Executor,
    Limits,
    Output,
    Prompt,
    Review,
    Snapshot,
    Trace
  }

  alias BurpeeTrainer.Coach.Client
  alias BurpeeTrainer.Workouts.Error

  def run(scope, prompt, opts, deadline, trace_id) do
    budget = Keyword.get_lazy(opts, :call_budget, fn -> CallBudget.new(scope, Limits.calls()) end)
    mode = Review.mode(opts)

    state = %{
      scope: scope,
      prompt: prompt,
      opts: opts,
      deadline: deadline,
      budget: budget,
      trace_id: trace_id,
      evidence: [],
      events: if(mode == :off, do: [%{"kind" => "review", "status" => "disabled"}], else: []),
      judgments: [],
      messages: [],
      queries: 0,
      calls: 0,
      reviews: 0,
      context_bytes: 0,
      interpretation: "",
      limitations: [],
      mode: mode,
      snapshot: nil,
      client_opts: []
    }

    with true <- state.mode in [:off, :shadow, :enforce],
         {:ok, client_opts} <-
           CallBudget.client_options(scope, budget, "analytics",
             call_allowance: Keyword.get(opts, :call_allowance, 8)
           ) do
      snapshot(%{state | client_opts: client_opts})
    else
      false ->
        error(:invalid_review_mode)

      {:error, :llm_budget_exhausted} ->
        fallback(state, "budget_exhausted", "Call allowance exhausted.")

      {:error, reason} ->
        error(reason)
    end
  end

  defp snapshot(state) do
    case Snapshot.build(state.scope,
           now: Keyword.get(state.opts, :now, DateTime.utc_now()),
           timeout: max(1, state.deadline - now() - Limits.reserve_ms())
         ) do
      {:ok, snapshot} ->
        loop(%{state | snapshot: snapshot, messages: Prompt.messages(state.prompt, snapshot)})

      {:error, :snapshot_too_large} ->
        fallback(
          state,
          "insufficient_data",
          "Snapshot coverage exceeds the bounded analysis limit; no subset was analyzed."
        )

      {:error, reason} ->
        error(reason)
    end
  end

  defp loop(state) do
    context = byte_size(Jason.encode!(state.messages))

    if exhausted?(state, context) do
      fallback(state, "budget_exhausted", "Analysis budget exhausted.")
    else
      opts = provider_opts(state, :analyst)

      result =
        Client.chat(
          state.messages,
          Keyword.put(opts, :response_format, {"analytics_action", Prompt.schema()})
        )

      state = %{state | calls: state.calls + 1, context_bytes: state.context_bytes + context}
      handle_response(state, result)
    end
  end

  defp handle_response(state, {:ok, %{content: content, tool_calls: [], usage: usage}})
       when is_map(content) do
    bytes = byte_size(Jason.encode!(content))

    state =
      event(state, %{
        "kind" => "analyst",
        "usage" => Limits.usage(usage)
      })

    if bytes + state.context_bytes > Limits.context_bytes() or bytes > Limits.narrative_bytes() do
      error(:analytics_context_too_large)
    else
      state = %{
        state
        | context_bytes: state.context_bytes + bytes,
          messages: state.messages ++ [%{role: "assistant", content: Jason.encode!(content)}]
      }

      action(state, content)
    end
  end

  defp handle_response(state, {:error, %{code: :llm_budget_exhausted}}),
    do: fallback(state, "budget_exhausted", "Call allowance exhausted.")

  defp handle_response(_state, {:error, error}), do: {:error, error}
  defp handle_response(_state, _), do: error(:invalid_analyst_action)

  defp action(
         state,
         %{
           "action" => "query",
           "interpretation" => interpretation,
           "intent" => intent,
           "sql" => sql
         } = proposal
       )
       when map_size(proposal) == 4 do
    if state.queries >= Limits.queries() do
      fallback(state, "budget_exhausted", "Query attempt limit reached.")
    else
      if Limits.text?(interpretation, Limits.interpretation_bytes()) and
           Limits.text?(intent, Limits.intent_bytes()) and
           Limits.text?(sql, Limits.sql_bytes()) do
        propose(%{state | interpretation: interpretation, queries: state.queries + 1}, proposal)
      else
        error(:invalid_analyst_action)
      end
    end
  end

  defp action(state, %{"action" => "final", "output" => output} = action)
       when map_size(action) == 2 do
    case Output.narrative(output, evidence_ids(state)) do
      {:ok, narrative} -> finalize(state, narrative)
      {:error, reason} -> error(reason)
    end
  end

  defp action(
         state,
         %{"action" => "clarify", "interpretation" => interpretation, "question" => question} =
           action
       )
       when map_size(action) == 3 do
    if Limits.text?(interpretation, 1024) and Limits.text?(question, 1024) do
      finalize(
        %{state | interpretation: interpretation},
        narrative(state, "needs_clarification", question)
        |> Map.put("interpretation", interpretation)
      )
    else
      error(:invalid_analyst_action)
    end
  end

  defp action(_, _), do: error(:invalid_analyst_action)

  defp propose(state, proposal) do
    state =
      event(state, %{
        "kind" => "proposal",
        "interpretation" => proposal["interpretation"],
        "intent" => proposal["intent"],
        "sql" => proposal["sql"]
      })

    case review(state, proposal) do
      {:execute, state} ->
        execute(state, proposal)

      {:revise, state, reason} ->
        continue(state, %{"review" => reason})

      {:clarify, state, reason} ->
        finalize(state, narrative(state, "needs_clarification", reason))

      {:exhausted, state} ->
        fallback(state, "budget_exhausted", "Review call allowance exhausted.")

      {:error, reason} ->
        error(reason)
    end
  end

  defp review(%{mode: :off} = state, _), do: {:execute, state}

  defp review(state, proposal) do
    case CallBudget.usage(state.scope, state.budget) do
      {:ok, %{remaining: 0}} ->
        review_result(state, {:error, :llm_budget_exhausted})

      {:ok, _} ->
        if state.reviews >= Limits.review_calls() or not fits?(state, Limits.review_ms()) do
          review_result(state, {:error, :llm_budget_exhausted})
        else
          review_call(state, proposal)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp review_call(state, proposal) do
    bytes = Review.context_bytes(state.prompt, proposal, state.evidence)

    if state.context_bytes + bytes + 1024 > Limits.context_bytes() do
      review_result(state, {:error, :llm_budget_exhausted})
    else
      result =
        Review.judge(state.prompt, proposal, state.evidence, provider_opts(state, :review))

      review_result(
        %{
          state
          | reviews: state.reviews + 1,
            context_bytes: state.context_bytes + bytes + 1024
        },
        result
      )
    end
  end

  defp review_result(state, result) do
    judgment =
      case result do
        {:ok, judgment} -> judgment
        {:error, reason} -> %{"error" => to_string(reason)}
      end

    state = %{state | judgments: state.judgments ++ [judgment]}

    reviewed(state.mode, state, result)
  end

  defp reviewed(_, _state, {:error, :ledger_unavailable}), do: {:error, :ledger_unavailable}

  defp reviewed(_, _state, {:error, :ledger_finalization_failed}),
    do: {:error, :ledger_finalization_failed}

  defp reviewed(:shadow, state, {:error, _}),
    do: {:execute, %{state | limitations: ["Query review unavailable; analysis is unreviewed."]}}

  defp reviewed(:shadow, state, {:ok, _}), do: {:execute, state}
  defp reviewed(:enforce, state, {:ok, %{"choice" => "proceed"}}), do: {:execute, state}

  defp reviewed(:enforce, state, {:ok, %{"choice" => "revise_query", "reason" => reason}}),
    do: {:revise, state, reason}

  defp reviewed(:enforce, state, {:ok, %{"choice" => "clarify_with_user", "reason" => reason}}),
    do: {:clarify, state, reason}

  defp reviewed(:enforce, state, {:error, :llm_budget_exhausted}), do: {:exhausted, state}
  defp reviewed(:enforce, _, {:error, _}), do: {:error, :review_unavailable}

  defp execute(state, proposal) do
    if fits?(state, 1000) do
      case Executor.query(state.snapshot, proposal["sql"], timeout_ms: 1000) do
        {:ok, result} ->
          evidence = %{
            "id" => "q#{length(state.evidence) + 1}",
            "intent" => proposal["intent"],
            "sql" => proposal["sql"],
            "columns" => result.columns,
            "rows" => result.rows
          }

          state =
            event(state, %{
              "kind" => "query_result",
              "evidence_id" => evidence["id"],
              "duration_ms" => result.duration_ms
            })

          loop(%{
            state
            | evidence: state.evidence ++ [evidence],
              messages:
                state.messages ++
                  [%{role: "user", content: Jason.encode!(%{"evidence" => evidence})}]
          })

        {:error, reason}
        when reason in [:sql_error, :sql_denied, :result_too_large, :query_timeout] ->
          state = event(state, %{"kind" => "query_error", "error" => to_string(reason)})
          continue(state, %{"query_error" => to_string(reason)})

        {:error, reason} ->
          error(reason)
      end
    else
      fallback(state, "budget_exhausted", "Query deadline exhausted.")
    end
  end

  defp continue(state, feedback) do
    if state.queries >= Limits.queries() do
      fallback(state, "budget_exhausted", "Query attempt limit reached.")
    else
      loop(%{
        state
        | messages: state.messages ++ [%{role: "user", content: Jason.encode!(feedback)}]
      })
    end
  end

  defp exhausted?(state, bytes),
    do:
      state.calls >= Limits.analyst_calls() or state.calls + state.reviews >= Limits.calls() or
        state.context_bytes + bytes > Limits.context_bytes() or
        not fits?(state, Limits.analyst_ms())

  defp fits?(state, ms), do: now() + ms + Limits.reserve_ms() <= state.deadline
  defp now, do: System.monotonic_time(:millisecond)
  defp evidence_ids(state), do: Enum.map(state.evidence, & &1["id"])
  defp event(state, event), do: %{state | events: state.events ++ [event]}

  defp provider_opts(state, role) do
    role_opts =
      if role == :review,
        do: Keyword.get(state.opts, :review, []),
        else: Keyword.take(state.opts, [:config, :req])

    ledger = %{
      state.client_opts[:ledger]
      | purpose: if(role == :review, do: "analytics_review", else: "analytics")
    }

    timeout = if role == :review, do: Limits.review_ms(), else: Limits.analyst_ms()

    Keyword.merge(role_opts,
      ledger: ledger,
      budget: state.client_opts[:budget],
      deadline_ms: min(state.deadline - Limits.reserve_ms(), now() + timeout)
    )
  end

  defp fallback(state, status, reason), do: finalize(state, narrative(state, status, reason))

  defp narrative(state, status, reason),
    do: %{
      "status" => status,
      "interpretation" => state.interpretation,
      "answer" => reason,
      "findings" => [],
      "limitations" => [reason]
    }

  defp finalize(state, narrative) do
    case Output.narrative(narrative, evidence_ids(state)) do
      {:ok, narrative} -> store_final(state, narrative)
      {:error, reason} -> error(reason)
    end
  end

  defp store_final(state, narrative) do
    narrative =
      Map.update!(narrative, "limitations", fn list ->
        Enum.take(Enum.uniq(state.limitations ++ list), 8)
      end)

    output = Map.merge(narrative, %{"evidence" => state.evidence, "trace_id" => state.trace_id})

    payload = %{
      "prompt" => state.prompt,
      "interpretation" => narrative["interpretation"],
      "schema_version" => 1,
      "review_mode" => Atom.to_string(state.mode),
      "coverage" => coverage(state.snapshot),
      "ledger_run_id" => state.budget.ledger_run_id,
      "evidence" => state.evidence,
      "events" => state.events,
      "judgments" => state.judgments,
      "final" => Map.put(narrative, "evidence_ids", evidence_ids(state))
    }

    with {:ok, output} <- Output.validate(output, evidence_ids(state)),
         :ok <-
           Trace.store(state.scope, state.trace_id, payload,
             timeout: max(1, min(1000, state.deadline - now()))
           ) do
      {:ok, output}
    else
      {:error, reason} -> error(reason)
    end
  end

  defp coverage(nil), do: nil

  defp coverage(snapshot),
    do: %{
      "as_of" => DateTime.to_iso8601(snapshot.as_of),
      "timezone" => snapshot.timezone,
      "rows" => length(snapshot.rows)
    }

  defp error(reason), do: {:error, Error.new(reason)}
end
