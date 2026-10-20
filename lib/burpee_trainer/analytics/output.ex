defmodule BurpeeTrainer.Analytics.Output do
  @moduledoc "Strict bounded shape and citation validation; not semantic correctness grading."
  alias BurpeeTrainer.Analytics.Limits
  @keys ~w(status interpretation answer findings limitations)
  @statuses ~w(answered needs_clarification insufficient_data budget_exhausted)
  @non_answers %{
    "needs_clarification" => [
      "Which training metric and comparison period should be analyzed?",
      "Reviewer selected clarification; define the intended comparison."
    ],
    "insufficient_data" => [
      "The available evidence is insufficient to answer this question.",
      "Snapshot coverage exceeds the bounded analysis limit; no subset was analyzed."
    ],
    "budget_exhausted" => [
      "Analysis budget exhausted.",
      "Analysis deadline exhausted.",
      "Call allowance exhausted.",
      "Query attempt limit reached.",
      "Review call allowance exhausted.",
      "Query deadline exhausted."
    ]
  }
  @unreviewed "Query review unavailable; analysis is unreviewed."

  def narrative(map, ids) when is_map(map) do
    valid =
      Enum.sort(Map.keys(map)) == Enum.sort(@keys) and
        map["status"] in @statuses and Limits.text?(map["interpretation"], 1024) and
        Limits.text?(map["answer"], 2048) and findings?(map["findings"], ids) and
        limitations?(map["limitations"]) and answered?(map, ids) and
        byte_size(Jason.encode!(map)) <= Limits.narrative_bytes()

    if valid, do: {:ok, safe_narrative(map)}, else: invalid()
  end

  def narrative(_, _), do: invalid()

  def validate(map, ids) when is_map(map) do
    with true <- Enum.sort(Map.keys(map)) == Enum.sort(@keys ++ ~w(evidence trace_id)),
         {:ok, _} <- Ecto.UUID.cast(map["trace_id"]),
         true <- evidence?(map["evidence"], ids),
         narrative = Map.take(map, @keys),
         {:ok, ^narrative} <- narrative(narrative, ids),
         true <- byte_size(Jason.encode!(map)) <= Limits.output_bytes() do
      {:ok, map}
    else
      _ -> invalid()
    end
  end

  def validate(_, _), do: invalid()

  defp safe_narrative(%{"status" => "answered"} = map), do: map

  # Non-answers are code-owned abstentions, not a second route for model claims.
  # This covers every free-text field, including spelled-out numbers.
  defp safe_narrative(map) do
    reasons = Map.fetch!(@non_answers, map["status"])
    reason = if map["answer"] in reasons, do: map["answer"], else: hd(reasons)
    limitations = if @unreviewed in map["limitations"], do: [@unreviewed, reason], else: [reason]

    %{
      "status" => map["status"],
      "interpretation" => "",
      "answer" => reason,
      "findings" => [],
      "limitations" => limitations
    }
  end

  defp findings?(list, ids) when is_list(list) do
    Enum.count_until(list, 9) <= 8 and
      Enum.all?(list, fn
        %{"text" => text, "evidence_ids" => refs} = finding when map_size(finding) == 2 ->
          Limits.text?(text, 1024) and is_list(refs) and Enum.count_until(refs, 4) <= 3 and
            Enum.all?(refs, &(&1 in ids))

        _ ->
          false
      end)
  end

  defp findings?(_, _), do: false

  defp limitations?(list) when is_list(list),
    do: Enum.count_until(list, 9) <= 8 and Enum.all?(list, &Limits.text?(&1, 1024))

  defp limitations?(_), do: false

  defp answered?(%{"status" => "answered", "findings" => findings}, ids),
    do: ids != [] and Enum.any?(findings, &(&1["evidence_ids"] != []))

  defp answered?(_, _), do: true

  defp evidence?(list, ids) when is_list(list) do
    Enum.count_until(list, 4) <= 3 and Enum.all?(list, &evidence_entry?/1) and
      Enum.map(list, & &1["id"]) == ids
  end

  defp evidence?(_, _), do: false

  defp evidence_entry?(
         %{"id" => id, "intent" => intent, "sql" => sql, "columns" => cols, "rows" => rows} = item
       ) do
    map_size(item) == 5 and Limits.text?(id, 16) and Limits.text?(intent, 512) and
      Limits.text?(sql, 4096) and columns?(cols) and rows?(rows, cols)
  end

  defp evidence_entry?(_), do: false

  defp columns?(cols) when is_list(cols),
    do: Enum.count_until(cols, 17) <= 16 and Enum.all?(cols, &Limits.text?(&1, 1024))

  defp columns?(_), do: false

  defp rows?(rows, cols) when is_list(rows) do
    Enum.count_until(rows, 101) <= 100 and
      Enum.all?(rows, fn row ->
        is_list(row) and length(row) == length(cols) and Enum.all?(row, &scalar?/1)
      end)
  end

  defp rows?(_, _), do: false

  defp scalar?(nil), do: true
  defp scalar?(x) when is_number(x), do: true
  defp scalar?(x), do: Limits.text?(x, 1024)
  defp invalid, do: {:error, :invalid_analytics_output}
end
