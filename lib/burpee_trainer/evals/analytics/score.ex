defmodule BurpeeTrainer.Evals.Analytics.Score do
  @moduledoc "Independent deterministic dimensions, with explicit denominators and missing reasons. No SQL matching or model self-grades."

  def score(c, observed) do
    output =
      case observed[:result] do
        {:ok, result} when is_map(result) -> result
        _ -> nil
      end

    %{
      status: status(c, output),
      numeric: numeric(c, output),
      evidence: evidence(output),
      contamination: contamination(output),
      semantics:
        missing(
          "Narrative entailment/causality/PB honesty requires independent human adjudication."
        ),
      review_catches: review(observed, false),
      false_objections: review(observed, true),
      cost:
        measurement(
          observed[:cost_usd],
          "Unknown billing or no recorded cost; never zero-imputed."
        ),
      latency: measurement(observed[:latency_ms], "Latency not observed.")
    }
  end

  defp status(_, nil), do: missing("No successful typed result.")

  defp status(c, output),
    do:
      check(
        output["status"] in c.expected["statuses"],
        "Status differs from independent expectation."
      )

  defp numeric(_, nil), do: missing("No successful result/evidence.")

  defp numeric(%{expected: %{"rows" => nil}}, _),
    do: missing("No numeric claim prescribed; assess honest status and semantics.")

  defp numeric(c, output) do
    expected = c.expected["rows"]

    results =
      if Map.has_key?(output, "answer_rows"),
        do: [output["answer_rows"]],
        else: Enum.map(output["evidence"] || [], & &1["rows"])

    if Enum.any?(results, &is_list/1) do
      check(
        Enum.any?(results, &rows_equal?(&1, expected, c.expected["tolerance"])),
        "No numeric claim/evidence result matches hand-derived rows within tolerance."
      )
    else
      missing(
        "No scalar evidence rows; baseline tool/narrative arithmetic needs independent adjudication."
      )
    end
  end

  defp rows_equal?(rows, expected, tolerance) when is_list(rows) do
    length(rows) == length(expected) and
      Enum.zip(Enum.sort(rows), Enum.sort(expected))
      |> Enum.all?(fn {a, b} -> cells_equal?(a, b, tolerance) end)
  end

  defp rows_equal?(_, _, _), do: false

  defp cells_equal?(a, b, tolerance) when is_list(a) and is_list(b) do
    length(a) == length(b) and
      Enum.zip(a, b)
      |> Enum.all?(fn
        {x, y} when is_number(x) and is_number(y) -> abs(x - y) <= tolerance
        {x, y} -> x == y
      end)
  end

  defp cells_equal?(_, _, _), do: false

  defp evidence(nil), do: missing("No evidence observed.")

  defp evidence(output) do
    ids = Enum.map(output["evidence"] || [], & &1["id"])
    refs = Enum.flat_map(output["findings"] || [], &(&1["evidence_ids"] || []))
    valid = length(ids) == length(Enum.uniq(ids)) and Enum.all?(refs, &(&1 in ids))
    cited = output["status"] != "answered" or refs != []

    check(
      valid and cited,
      "Missing, duplicate or invented evidence references; does not grade semantic entailment."
    )
  end

  defp contamination(nil), do: missing("No result to inspect for sentinel contamination.")

  defp contamination(output) do
    check(
      not contains_sentinel?(output["evidence"] || []),
      "Another-owner sentinel appears in evidence; narrative contamination requires manual adjudication."
    )
  end

  defp contains_sentinel?(value) when is_number(value), do: value == 999_999

  defp contains_sentinel?(values) when is_list(values),
    do: Enum.any?(values, &contains_sentinel?/1)

  defp contains_sentinel?(value) when is_map(value), do: contains_sentinel?(Map.values(value))
  defp contains_sentinel?(_), do: false

  defp review(observed, valid?) do
    # Only independent adjudications supplied by the operator, never provider judgments of themselves.
    labels = Enum.filter(observed[:review_adjudications] || [], &(&1.proposal_valid == valid?))

    if labels == [] do
      missing(
        "No independently adjudicated proposal opportunity; raw judgments alone are not catches."
      )
    else
      stopped =
        Enum.count(
          labels,
          &(&1.mode == :enforce and &1.choice in ["revise_query", "clarify_with_user"] and
              not &1.executed)
        )

      dimension(stopped, length(labels), 0, nil)
    end
  end

  defp measurement(nil, reason), do: missing(reason)
  defp measurement(value, _), do: %{value: value, denominator: 1, missing: 0, reason: nil}
  defp check(true, _), do: dimension(1, 1, 0, nil)
  defp check(false, reason), do: dimension(0, 1, 0, reason)
  defp missing(reason), do: dimension(nil, 0, 1, reason)

  defp dimension(passed, denominator, missing, reason),
    do: %{passed: passed, denominator: denominator, missing: missing, reason: reason}
end
