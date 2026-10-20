defmodule BurpeeTrainer.Analytics.Review do
  @moduledoc "Experimental typed query judgment; never a SQL permission boundary."
  alias BurpeeTrainer.Analytics.{Limits, Schema}
  alias BurpeeTrainer.Coach.Client
  @choices ~w(proceed revise_query clarify_with_user)

  def mode(opts) do
    config = Application.get_env(:burpee_trainer, :analytics_review, [])
    Keyword.get(opts, :review_mode, Keyword.get(config, :mode, :shadow))
  end

  def judge(prompt, proposal, evidence, opts) do
    {state, question} = context(prompt, proposal, evidence)

    case Client.decide(state, question, opts) do
      {:ok, %{answers: answers, usage: usage}} ->
        with {:ok, judgment} <- validate(answers) do
          {:ok,
           Map.put(
             judgment,
             "usage",
             Limits.usage(usage)
           )}
        end

      {:error, error} ->
        {:error, error.code}
    end
  end

  def context_bytes(prompt, proposal, evidence) do
    {state, questions} = context(prompt, proposal, evidence)
    byte_size(Jason.encode!(%{state: state, questions: questions}))
  end

  defp context(prompt, proposal, evidence) do
    state = %{
      question: prompt,
      proposal: proposal,
      definitions: Schema.text(),
      preceding_evidence: evidence
    }

    question = %{
      "query_review" => %{
        "type" => "choice",
        "instructions" =>
          "Does the proposed read-only query address the question and metric definitions without misleading comparisons? Permissions are enforced separately.",
        "criteria" => %{
          "proceed" => "Suitable query",
          "revise_query" => "Needs a better query",
          "clarify_with_user" => "Question requires clarification"
        }
      }
    }

    {state, question}
  end

  def validate(%{"query_review" => %{"choice" => choice} = answer} = answers)
      when map_size(answers) == 1 and choice in @choices do
    valid =
      Enum.all?(Map.keys(answer), &(&1 in ~w(choice confidence probabilities))) and
        confidence?(answer["confidence"]) and probabilities?(answer["probabilities"]) and
        byte_size(Jason.encode!(answers)) <= Limits.interpretation_bytes()

    if valid,
      do: {:ok, %{"choice" => choice, "reason_source" => "code", "reason" => reason(choice)}},
      else: {:error, :review_unavailable}
  end

  def validate(_), do: {:error, :review_unavailable}

  defp confidence?(nil), do: true
  defp confidence?(value), do: is_number(value) and value >= 0 and value <= 1
  defp probabilities?(nil), do: true

  defp probabilities?(map) when is_map(map) and map_size(map) <= 3,
    do: Enum.all?(map, fn {k, v} -> k in @choices and is_number(v) and v >= 0 and v <= 1 end)

  defp probabilities?(_), do: false
  defp reason("proceed"), do: "Reviewer selected proceed."
  defp reason("revise_query"), do: "Reviewer selected revise_query; propose a different query."

  defp reason("clarify_with_user"),
    do: "Reviewer selected clarification; define the intended comparison."
end
