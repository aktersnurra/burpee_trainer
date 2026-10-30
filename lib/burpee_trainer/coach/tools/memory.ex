defmodule BurpeeTrainer.Coach.Tools.Memory do
  @moduledoc """
  The coach's memory tool, shaped as the Hermes agent's: one `target` store and a batch of
  `operations` (add, patch, remove), applied all or nothing (`Memory.write/3`). Success and
  rejection both come back as the store's live entries and usage, so the coach can retry.
  Shared with Claude through MCP (`update_memory`).
  """
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Memory, Tool}

  def name, do: "memory"

  def description,
    do:
      "Keep what you remember about the athlete. target user is who they are (schedule, " <>
        "body, likes, what they train for); memory is your notes on coaching them (what " <>
        "worked, what you agreed). operations, applied together or not at all: add " <>
        "{content}; patch {old_text, content} replaces old_text inside the one entry that " <>
        "holds it; remove {old_text} deletes the one entry that holds it. Both parts have a " <>
        "size limit checked on the batch's result, so free space and add in one batch. " <>
        "Returns the part's entries and usage, or why nothing changed."

  def schema do
    operation = %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ~w[add patch remove]},
        "content" => %{
          "type" => "string",
          "description" => "The entry to add, or the replacement for old_text."
        },
        "old_text" => %{
          "type" => "string",
          "description" => "Text that identifies one entry, for patch and remove."
        }
      },
      "required" => ["action"],
      "additionalProperties" => false
    }

    Tool.object(
      %{
        "target" => %{"type" => "string", "enum" => ~w[user memory]},
        "operations" => %{
          "type" => "array",
          "items" => operation,
          "minItems" => 1,
          "maxItems" => 10
        }
      },
      ["target", "operations"]
    )
  end

  def call(scope, %{"target" => target, "operations" => operations} = args, _run)
      when map_size(args) == 2 and target in ~w[user memory] do
    case Memory.write(scope, target, operations) do
      {:ok, %{"changed" => true} = result} -> {:ok, result, %{memory_written?: true}}
      {:ok, result} -> {:ok, result}
      {:error, rejection} -> {:ok, rejection}
    end
  end

  def call(_scope, _args, _run),
    do: {:error, "memory takes target (user or memory) and operations"}
end
