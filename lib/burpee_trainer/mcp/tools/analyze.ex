defmodule BurpeeTrainer.Mcp.Tools.Analyze do
  @moduledoc "Thin MCP adapter; only trusted code selects scope, review mode and budgets."
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Analytics
  alias BurpeeTrainer.Analytics.Limits
  alias BurpeeTrainer.Coach.Tool

  def name, do: "analyze"

  def description,
    do:
      "Investigate a training question using bounded read-only SQL over your completed sessions. " <>
        "Returns evidence, limitations and a private trace ID; may clarify or abstain. " <>
        "Evidence provenance is checked, not semantic correctness. See burpee://analytics/schema."

  def schema,
    do:
      Tool.object(
        %{
          "prompt" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => Limits.prompt_bytes(),
            "description" => "Nonempty UTF-8 question, at most 4096 UTF-8 bytes."
          }
        },
        ["prompt"]
      )

  def call(scope, %{"prompt" => prompt} = args, _) when map_size(args) == 1 do
    if Limits.text?(prompt, Limits.prompt_bytes()) and byte_size(prompt) > 0 do
      case Analytics.analyze(scope, prompt) do
        {:ok, output} ->
          {:ok, output}

        {:error, %BurpeeTrainer.Workouts.Error{code: code}} ->
          {:error, Jason.encode!(%{"code" => to_string(code)})}
      end
    else
      invalid()
    end
  end

  def call(_, _, _), do: invalid()
  defp invalid, do: {:error, Jason.encode!(%{"code" => "invalid_prompt"})}

  def output_schema do
    Tool.object(
      %{
        "status" => %{
          "type" => "string",
          "enum" => ~w(answered needs_clarification insufficient_data budget_exhausted)
        },
        "interpretation" => text(),
        "answer" => text(),
        "findings" =>
          array(
            Tool.object(
              %{"text" => text(), "evidence_ids" => array(text(), 3)},
              ~w(text evidence_ids)
            ),
            8
          ),
        "evidence" =>
          array(
            Tool.object(
              %{
                "id" => text(),
                "intent" => text(),
                "sql" => text(),
                "columns" => array(text(), 16),
                "rows" => array(array(%{"type" => ["string", "number", "null"]}, 16), 100)
              },
              ~w(id intent sql columns rows)
            ),
            3
          ),
        "limitations" => array(text(), 8),
        "trace_id" => %{"type" => "string", "format" => "uuid"}
      },
      ~w(status interpretation answer findings evidence limitations trace_id)
    )
  end

  defp text, do: %{"type" => "string"}
  defp array(items, max), do: %{"type" => "array", "items" => items, "maxItems" => max}
end
