defmodule BurpeeTrainer.Insights.Validator do
  @moduledoc "Rejects narration unless each numeric token exactly matches a cited formatted metric."
  alias BurpeeTrainer.Insights.Metrics
  # Consume the entire numeric token: never accept a substring of a sign,
  # grouped number, Unicode digit sequence, fraction or scientific notation.
  @sentence_end ~r/[.!?](?=\s|$)/u
  @number ~r/[+−-]?(?:\p{N}+(?:[,\.]\p{N}+)*|\.\p{N}+)(?:[eE][+−-]?\p{N}+)?/u

  @spec validate(term(), map()) :: {:ok, map()} | {:error, term()}
  def validate(%{"headline" => headline, "points" => points} = insight, metrics)
      when is_binary(headline) and is_list(points) and is_map(metrics) do
    with :ok <- length_ok(headline, 80),
         :ok <- if(String.trim(headline) != "", do: :ok, else: {:error, :invalid_shape}),
         :ok <- if(length(points) <= 3, do: :ok, else: {:error, :too_many_points}),
         :ok <- numbers_supported(headline, [], metrics),
         :ok <- Enum.reduce_while(points, :ok, &point(&1, &2, metrics)) do
      {:ok, insight}
    end
  end

  def validate(_, _), do: {:error, :invalid_shape}

  @doc "A coach summary: at most two sentences whose every number is a cited metric value."
  @spec validate_summary(term(), map()) :: {:ok, map()} | {:error, term()}
  def validate_summary(%{"text" => text, "metric_ids" => ids} = summary, metrics)
      when is_binary(text) and is_list(ids) and is_map(metrics) do
    with :ok <- length_ok(text, 280),
         :ok <- if(String.trim(text) != "", do: :ok, else: {:error, :invalid_shape}),
         :ok <- sentences_ok(text, 2),
         :ok <- known(ids, metrics),
         :ok <- numbers_supported(text, ids, metrics) do
      {:ok, summary}
    end
  end

  def validate_summary(_, _), do: {:error, :invalid_shape}

  defp point(%{"text" => text, "metric_ids" => ids}, :ok, metrics)
       when is_binary(text) and is_list(ids) do
    result =
      with :ok <- length_ok(text, 160),
           :ok <- known(ids, metrics),
           do: numbers_supported(text, ids, metrics)

    if result == :ok, do: {:cont, :ok}, else: {:halt, result}
  end

  defp point(_, :ok, _), do: {:halt, {:error, :invalid_shape}}

  defp length_ok(text, max) do
    cond do
      not String.valid?(text) -> {:error, :invalid_shape}
      String.length(text) > max -> {:error, :too_long}
      true -> :ok
    end
  end

  # A sentence ends at ".", "!" or "?" followed by whitespace or the end, so "4.8" is one token.
  defp sentences_ok(text, max) do
    if length(Regex.scan(@sentence_end, text)) <= max,
      do: :ok,
      else: {:error, :too_many_sentences}
  end

  defp known(ids, metrics) do
    cond do
      not Enum.all?(ids, &is_binary/1) ->
        {:error, :invalid_shape}

      true ->
        case Enum.find(ids, &(not Map.has_key?(metrics, &1))) do
          nil -> :ok
          id -> {:error, {:unknown_metric, id}}
        end
    end
  end

  defp numbers_supported(text, ids, metrics) do
    cited = Enum.map(ids, &Map.fetch!(metrics, &1))
    allowed = cited |> Enum.filter(&is_number(&1.value)) |> MapSet.new(&Metrics.format/1)

    text =
      Enum.reduce(cited, text, fn
        %{unit: :level, value: value}, acc when is_binary(value) ->
          Regex.replace(
            Regex.compile!(
              "(?<![\\p{L}\\p{N}_])" <> Regex.escape(value) <> "(?![\\p{L}\\p{N}_])",
              "u"
            ),
            acc,
            ""
          )

        _, acc ->
          acc
      end)

    case Enum.find(
           Regex.scan(@number, text) |> List.flatten(),
           &(not MapSet.member?(allowed, &1))
         ) do
      nil -> :ok
      token -> {:error, {:unsupported_number, token}}
    end
  end
end
