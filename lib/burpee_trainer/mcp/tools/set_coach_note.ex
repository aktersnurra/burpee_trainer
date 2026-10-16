defmodule BurpeeTrainer.Mcp.Tools.SetCoachNote do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Summary, Tool, Voice}

  @max_text 280
  @max_review 400

  def name, do: "set_coach_note"

  def description,
    do:
      "Write the coach's note on Home: text, your word on the rest of the week in one or " <>
        "two short sentences, and optionally review, a look back shown at the top of " <>
        "Progress. Plain words for the athlete, no internal names such as level_1b. When " <>
        "the athlete has the app's own coach, its next weekly note replaces yours."

  def schema,
    do:
      Tool.object(
        %{
          "text" => %{"type" => "string", "maxLength" => @max_text},
          "review" => %{"type" => "string", "maxLength" => @max_review}
        },
        ["text"]
      )

  def call(scope, %{"text" => text} = args, _) when map_size(args) in [1, 2] do
    review = Map.get(args, "review")

    with [] <- Map.keys(args) -- ["text", "review"],
         {:ok, text} <- plain(text, @max_text, "text"),
         {:ok, review} <- if(review, do: plain(review, @max_review, "review"), else: {:ok, nil}),
         {:ok, summary} <-
           Summary.store(scope, %{
             text: text,
             review: review,
             source: :claude,
             metric_ids: [],
             suggestions: []
           }) do
      Summary.broadcast(scope, summary)
      {:ok, %{"text" => summary.text, "review" => summary.review}}
    else
      [_ | _] = unknown -> {:error, "unknown fields: #{Enum.join(unknown, ", ")}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "the note could not be saved"}
    end
  end

  def call(_, _, _), do: {:error, "set_coach_note takes text and optionally review"}

  defp plain(value, max, field) when is_binary(value) do
    value = value |> String.split() |> Enum.join(" ")

    cond do
      value == "" ->
        {:error, "#{field} is empty"}

      String.length(value) > max ->
        {:error, "#{field} must be at most #{max} characters"}

      id = Voice.internal_id(value) ->
        {:error, "#{field} is shown to the athlete; write #{id} in plain words"}

      true ->
        {:ok, value}
    end
  end

  defp plain(_value, _max, field), do: {:error, "#{field} must be a string"}
end
