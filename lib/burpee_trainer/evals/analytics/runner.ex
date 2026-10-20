defmodule BurpeeTrainer.Evals.Analytics.Runner do
  @moduledoc "Serial read-only comparison. Offline by default; live requires explicit owner opt-in and one shared durable call ceiling."
  import Ecto.Query
  alias BurpeeTrainer.Analytics
  alias BurpeeTrainer.Analytics.{CallBudget, Output, Snapshot, Trace}
  alias BurpeeTrainer.Coach.{Client, LlmCall, Tool}
  alias BurpeeTrainer.Evals.Analytics.{Corpus, Score}
  alias BurpeeTrainer.Mcp.Tools.{HistoryStats, Progress, QueryHistory, Week}
  alias BurpeeTrainer.Repo

  @tools [QueryHistory, HistoryStats, Progress, Week]

  def run(scope, cases, opts \\ []) do
    mode = Keyword.get(opts, :mode, :offline)

    with :ok <- admission(mode, opts), :ok <- budget_ceiling(mode, opts) do
      budget = budget(scope, mode, opts)

      report = %{
        version: 1,
        fixture_version: Corpus.version(),
        mode: label(mode),
        calls: calls(mode),
        records: [],
        halted: nil,
        limitations: [
          "Recorded protocol regressions are not model benchmarks.",
          "Five held-out cases are public/inspected, not secret.",
          "Narrative semantics and review opportunities need independent adjudication.",
          "Existing baseline tools use their actual wall clock and broader read-only history fields; no clock equivalence is claimed."
        ]
      }

      jobs = for c <- cases, arm <- Keyword.get(opts, :arms, [:a, :b, :c]), do: {c, arm}

      compare(jobs, report, scope, mode, budget, opts)
    end
  end

  defp budget_ceiling(:offline, _), do: :ok

  defp budget_ceiling(_, opts) do
    case opts[:call_budget] do
      %CallBudget{ceiling: ceiling} when ceiling > 0 ->
        if ceiling <= Keyword.get(opts, :max_calls, 0),
          do: :ok,
          else: {:error, :call_budget_exceeds_ceiling}

      _ ->
        :ok
    end
  end

  defp budget(_, :offline, _), do: nil

  defp budget(scope, _, opts) do
    Keyword.get_lazy(opts, :call_budget, fn ->
      CallBudget.new(scope, Keyword.get(opts, :max_calls, 0))
    end)
  end

  defp compare(jobs, report, scope, mode, budget, opts) do
    Enum.reduce_while(jobs, {:ok, report}, fn {c, arm}, {:ok, report} ->
      case arm_record(scope, c, arm, mode, budget, opts) do
        {:ok, record} ->
          {:cont, {:ok, %{report | records: [record | report.records]}}}

        {:halt, record, reason} ->
          halted = %{report | records: [record | report.records], halted: reason}
          {:halt, {:error, %{reason: reason, report: halted}}}

        {:error, reason} ->
          {:halt, {:error, %{reason: reason, report: %{report | halted: reason}}}}
      end
    end)
    |> ordered_records()
  end

  defp ordered_records({:ok, report}),
    do: {:ok, %{report | records: Enum.reverse(report.records)}}

  defp ordered_records({:error, %{report: report} = error}),
    do: {:error, %{error | report: %{report | records: Enum.reverse(report.records)}}}

  defp admission(:offline, _), do: :ok

  defp admission(:live, opts) do
    cond do
      opts[:owner_opt_in] != true ->
        {:error, :live_opt_in_required}

      not (is_integer(opts[:max_calls]) and opts[:max_calls] > 0) ->
        {:error, :positive_call_budget_required}

      true ->
        :ok
    end
  end

  defp admission(:recorded, opts) do
    arms = Keyword.get(opts, :arms, [:a, :b, :c])
    analyst = Keyword.get(opts, :analyst_options, [])

    providers =
      Enum.flat_map(arms, fn
        :a -> [Keyword.get(opts, :baseline_options, [])]
        :b -> [analyst]
        :c -> [analyst, Keyword.get(analyst, :review, [])]
        _ -> [[]]
      end)

    if providers != [] and Enum.all?(providers, &recorded_provider?/1) do
      :ok
    else
      {:error, :recorded_transport_required}
    end
  end

  defp admission(_, _), do: {:error, :invalid_mode}

  defp recorded_provider?(opts) do
    config = opts[:config] || []
    host = URI.parse(config[:url] || "").host

    is_binary(host) and String.ends_with?(host, ".test") and
      match?(%Req.Request{options: %{plug: plug}} when not is_nil(plug), opts[:req])
  end

  defp arm_record(_, c, arm, :offline, _, opts) when arm in [:a, :b, :c] do
    result =
      Map.get(Keyword.get(opts, :recordings, %{}), {c.id, arm}, {:error, :missing_recording})

    observed = %{
      result: result,
      cost_usd: nil,
      latency_ms: nil,
      review_events: %{missing: :offline_not_observed}
    }

    usage = %{before: %{reservations: 0}, after: %{reservations: 0}, calls: []}
    {:ok, record(c, arm, observed, usage)}
  end

  defp arm_record(scope, c, arm, mode, budget, opts) when arm in [:a, :b, :c] do
    with {:ok, before} <- settled_usage(scope, budget), :ok <- fixture_check(scope, c, mode) do
      start = System.monotonic_time(:millisecond)
      result = dispatch(scope, c, arm, mode, budget, before.remaining, opts)

      observed = %{
        result: result,
        latency_ms: System.monotonic_time(:millisecond) - start,
        review_events: review_events(scope, result),
        cost_usd: nil
      }

      complete_record(scope, budget, c, arm, observed, before)
    end
  end

  defp arm_record(_, _, _, _, _, _), do: {:error, :invalid_arm}

  defp complete_record(scope, budget, c, arm, observed, before) do
    case CallBudget.usage(scope, budget) do
      {:ok, after_usage} ->
        billed_record(scope, budget, c, arm, observed, before, after_usage)

      {:error, reason} ->
        usage = %{before: before, after: nil, calls: [], error: reason}
        {:halt, record(c, arm, observed, usage), reason}
    end
  end

  defp billed_record(scope, budget, c, arm, observed, before, after_usage) do
    case billing(scope, budget, before.reservations, after_usage.reservations) do
      {:ok, billing} ->
        usage = %{before: before, after: after_usage, calls: billing.calls}
        record = record(c, arm, %{observed | cost_usd: billing.cost_usd}, usage)

        if after_usage.inflight == 0,
          do: {:ok, record},
          else: {:halt, record, :inflight_reservations}

      {:error, reason} ->
        usage = %{before: before, after: after_usage, calls: [], error: reason}
        {:halt, record(c, arm, observed, usage), reason}
    end
  end

  defp record(c, arm, observed, usage) do
    %{
      case_id: c.id,
      dataset: c.dataset,
      fixture_version: Corpus.version(),
      partition: c.partition,
      arm: arm,
      result: export_result(observed.result),
      score: Score.score(c, observed),
      usage: usage,
      cost_usd: observed.cost_usd,
      latency_ms: observed.latency_ms,
      review_events: observed.review_events
    }
  end

  defp settled_usage(scope, budget) do
    case CallBudget.usage(scope, budget) do
      {:ok, %{inflight: 0} = usage} -> {:ok, usage}
      {:ok, _} -> {:error, :inflight_reservations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fixture_check(scope, c, _) do
    dataset = Corpus.dataset(c.dataset)

    with {:ok, snapshot} <- Snapshot.build(scope, now: ~U[9999-12-31 23:59:59Z]),
         true <- Corpus.matches?(snapshot, dataset) do
      :ok
    else
      false -> {:error, :fixture_mismatch}
      error -> error
    end
  end

  defp dispatch(_, _, _, _, _, 0, _), do: {:error, :llm_budget_exhausted}
  defp dispatch(scope, c, :a, _, budget, _, opts), do: baseline(scope, c, budget, opts)

  defp dispatch(scope, c, arm, _, budget, remaining, opts) do
    controls = [
      call_budget: budget,
      call_allowance: remaining,
      review_mode: if(arm == :b, do: :off, else: :enforce),
      now: Corpus.now(Corpus.dataset(c.dataset))
    ]

    Analytics.analyze(
      scope,
      c.prompt,
      Keyword.merge(Keyword.get(opts, :analyst_options, []), controls)
    )
  end

  defp baseline(scope, c, budget, opts) do
    messages = [
      %{
        role: "system",
        content:
          "Read-only training analysis. Use only supplied tools. Do not infer causality or certify normalized pace as PB. Clarify ambiguous improvement. Return JSON with status, interpretation, answer, findings [{text,evidence_ids}], limitations, and answer_rows (array of rows of scalar numeric/text claims in your answer, or [] if none; at most 100 rows, 16 cells each). Cite generated a1 etc. No SQL or mutations. Current fixture as-of: #{Corpus.dataset(c.dataset)["now"]}."
      },
      %{role: "user", content: c.prompt}
    ]

    baseline_loop(%{
      scope: scope,
      budget: budget,
      messages: messages,
      evidence: [],
      turns: 0,
      opts: opts,
      deadline: System.monotonic_time(:millisecond) + 30_000
    })
  end

  defp baseline_loop(%{turns: turns}) when turns >= 5, do: {:error, :baseline_turn_limit}

  defp baseline_loop(state) do
    with {:ok, usage} <- settled_usage(state.scope, state.budget),
         {:ok, controls} <-
           CallBudget.client_options(state.scope, state.budget, "analytics_baseline",
             call_allowance: usage.remaining
           ) do
      provider = Keyword.get(state.opts, :baseline_options, [])

      options =
        Keyword.merge(
          provider,
          controls ++
            [
              tools: Enum.map(@tools, &Tool.definition/1),
              deadline_ms: min(state.deadline, System.monotonic_time(:millisecond) + 5000)
            ]
        )

      case Client.chat(state.messages, options) do
        {:ok, %{tool_calls: [], content: content}} -> baseline_final(content, state.evidence)
        {:ok, %{tool_calls: [call]}} -> baseline_tool(state, call)
        {:ok, _} -> {:error, :baseline_one_tool_per_turn}
        error -> error
      end
    end
  end

  defp baseline_tool(state, call) do
    case Enum.find(@tools, &(&1.name() == call.name)) do
      nil -> {:error, :baseline_tool_denied}
      module -> baseline_tool_result(state, call, module.call(state.scope, call.arguments, %{}))
    end
  end

  defp baseline_tool_result(_, _, {:error, _}), do: {:error, :baseline_tool_error}

  defp baseline_tool_result(state, call, {:ok, result}) do
    {entry, exchanges} = tool_exchange(call, result, length(state.evidence) + 1)
    next_messages = state.messages ++ exchanges

    if byte_size(Jason.encode!(next_messages)) <= 65_536 do
      baseline_loop(%{
        state
        | messages: next_messages,
          evidence: state.evidence ++ [entry],
          turns: state.turns + 1
      })
    else
      {:error, :baseline_context_limit}
    end
  end

  defp tool_exchange(call, result, index) do
    entry = %{"id" => "a#{index}", "tool" => call.name, "result" => result}

    assistant = %{
      role: "assistant",
      content: nil,
      tool_calls: [
        %{
          id: call.id,
          type: "function",
          function: %{name: call.name, arguments: Jason.encode!(call.arguments)}
        }
      ]
    }

    reply = %{role: "tool", tool_call_id: call.id, content: Jason.encode!(entry)}
    {entry, [assistant, reply]}
  end

  defp baseline_final(content, evidence) when is_binary(content) do
    with {:ok, output} <- Jason.decode(content),
         true <- answer_rows?(output["answer_rows"]),
         {:ok, narrative} <-
           Output.narrative(Map.delete(output, "answer_rows"), Enum.map(evidence, & &1["id"])) do
      {:ok,
       Map.merge(narrative, %{"evidence" => evidence, "answer_rows" => output["answer_rows"]})}
    else
      _ -> {:error, :invalid_baseline_output}
    end
  end

  defp baseline_final(_, _), do: {:error, :invalid_baseline_output}

  defp answer_rows?(rows) when is_list(rows) do
    Enum.count_until(rows, 101) <= 100 and byte_size(Jason.encode!(rows)) <= 8192 and
      Enum.all?(rows, &answer_row?/1)
  end

  defp answer_rows?(_), do: false

  defp answer_row?(row) when is_list(row) do
    Enum.count_until(row, 17) <= 16 and
      Enum.all?(row, &(is_number(&1) or is_binary(&1) or is_nil(&1)))
  end

  defp answer_row?(_), do: false

  defp billing(scope, budget, before, after_count) do
    count = max(after_count - before, 0)

    query =
      from(c in LlmCall,
        where: c.user_id == ^scope.user.id and c.run_id == ^budget.ledger_run_id,
        order_by: c.id,
        offset: ^before,
        limit: ^count
      )

    rows = Repo.all(query, timeout: 1000)
    known = rows != [] and Enum.all?(rows, &(not is_nil(&1.cost_usd)))

    {:ok,
     %{
       cost_usd: if(known, do: Enum.reduce(rows, 0.0, &(&1.cost_usd + &2))),
       calls:
         Enum.map(
           rows,
           &Map.take(&1, [
             :purpose,
             :model,
             :prompt_tokens,
             :completion_tokens,
             :cost_usd,
             :outcome,
             :duration_ms
           ])
         )
     }}
  rescue
    _ in [DBConnection.ConnectionError, Exqlite.Error] -> {:error, :billing_unavailable}
  end

  defp review_events(scope, {:ok, %{"trace_id" => id}}) do
    case Trace.fetch(scope, id) do
      {:ok, trace} -> %{judgments: trace["judgments"], events: trace["events"]}
      {:error, reason} -> %{missing: reason}
    end
  end

  defp review_events(_, _), do: %{missing: :no_trace}
  defp export_result({:ok, output}), do: %{ok: true, output: output}
  defp export_result({:error, %{code: code}}), do: %{ok: false, error: code}
  defp export_result({:error, reason}), do: %{ok: false, error: reason}
  defp label(:offline), do: "offline_protocol"
  defp label(:recorded), do: "recorded_protocol"
  defp label(:live), do: "live_owner_comparison"
  defp calls(:offline), do: "none"
  defp calls(:recorded), do: "recorded"
  defp calls(:live), do: "live"
end
