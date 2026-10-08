defmodule BurpeeTrainer.Evals.Results do
  @moduledoc "Eval outcomes derived from actual scoped ledger rows, preserving unknown provider usage."
  def scenario(id, outcome, calls) do
    success? = match?({:ok, _}, outcome)
    layouts = Enum.count(calls, &(&1.purpose == "layout"))

    known_cost =
      calls
      |> Enum.flat_map(&if(is_number(&1.cost_usd), do: [&1.cost_usd], else: []))
      |> Enum.sum()

    unknown = Enum.count(calls, &is_nil(&1.cost_usd))

    %{
      id: id,
      success: success?,
      first_try_fit: success? and layouts == 1,
      repaired: success? and layouts == 2,
      failure_reason: failure(outcome),
      calls: length(calls),
      prompt_tokens: measured_sum(calls, :prompt_tokens),
      completion_tokens: measured_sum(calls, :completion_tokens),
      known_prompt_tokens: sum(calls, :prompt_tokens),
      known_completion_tokens: sum(calls, :completion_tokens),
      missing_prompt_usage_calls: Enum.count(calls, &is_nil(&1.prompt_tokens)),
      missing_completion_usage_calls: Enum.count(calls, &is_nil(&1.completion_tokens)),
      cost_usd: if(unknown == 0, do: known_cost, else: nil),
      known_cost_usd: known_cost + 0.0,
      unknown_cost_calls: unknown,
      duration_ms: sum(calls, :duration_ms),
      outcomes: Enum.map(calls, & &1.outcome)
    }
  end

  def total(rows) do
    count = length(rows)
    first = Enum.count(rows, & &1.first_try_fit)
    unknown = sum(rows, :unknown_cost_calls)

    %{
      scenarios: count,
      first_try_fits: first,
      first_try_fit_rate: if(count > 0, do: first / count),
      repairs_succeeded: Enum.count(rows, & &1.repaired),
      successes: Enum.count(rows, & &1.success),
      calls: sum(rows, :calls),
      prompt_tokens: measured_sum(rows, :prompt_tokens),
      completion_tokens: measured_sum(rows, :completion_tokens),
      known_prompt_tokens: sum(rows, :known_prompt_tokens),
      known_completion_tokens: sum(rows, :known_completion_tokens),
      duration_ms: sum(rows, :duration_ms),
      cost_usd: if(unknown == 0, do: sum(rows, :known_cost_usd), else: nil),
      known_cost_usd: sum(rows, :known_cost_usd),
      unknown_cost_calls: unknown,
      missing_prompt_usage_calls: sum(rows, :missing_prompt_usage_calls),
      missing_completion_usage_calls: sum(rows, :missing_completion_usage_calls)
    }
  end

  defp measured_sum(rows, field),
    do: if(Enum.any?(rows, &is_nil(Map.fetch!(&1, field))), do: nil, else: sum(rows, field))

  defp sum(rows, field), do: rows |> Enum.map(&(Map.fetch!(&1, field) || 0)) |> Enum.sum()
  defp failure({:ok, _}), do: nil
  defp failure({:error, %{code: code}}), do: to_string(code)
  defp failure({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure({:error, _}), do: "invalid_authoring_result"
end
