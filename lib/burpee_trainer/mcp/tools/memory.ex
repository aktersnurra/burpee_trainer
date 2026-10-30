defmodule BurpeeTrainer.Mcp.Tools.ListMemory do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Memory, Tool}

  def name, do: "list_memory"

  def description,
    do:
      "The coach's memory of the athlete, shared with the app's own coach: user (who they " <>
        "are) and memory (notes on coaching them), each with its entries, oldest first, and " <>
        "its usage against its size limit. Change it with update_memory."

  def schema, do: Tool.object(%{}, [])

  def call(scope, args, _) when is_map(args) and map_size(args) == 0,
    do:
      {:ok,
       Map.new(Memory.stores(scope), fn %{store: store, entries: entries, usage: usage} ->
         {store,
          %{
            "usage" => usage,
            "entries" =>
              Enum.map(entries, fn entry ->
                %{
                  "text" => entry.text,
                  "noted_on" => Date.to_iso8601(DateTime.to_date(entry.inserted_at))
                }
              end)
          }}
       end)}

  def call(_, _, _), do: {:error, "list_memory takes no arguments"}
end

defmodule BurpeeTrainer.Mcp.Tools.UpdateMemory do
  @moduledoc "The app coach's memory tool (`Coach.Tools.Memory`) for Claude: the same batches."
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Memory, Tool, Tools}

  def name, do: "update_memory"

  def description,
    do:
      Tools.Memory.description() <>
        " The athlete sees each change in the app. Not results (reps, times, levels), which " <>
        "are kept elsewhere, and no internal names such as six_count (write six-count)."

  def schema, do: Tools.Memory.schema()

  def call(scope, %{"target" => target, "operations" => operations} = args, _)
      when map_size(args) == 2 and target in ~w[user memory] do
    case Memory.write(scope, target, operations) do
      {:ok, result} -> {:ok, result}
      {:error, rejection} -> {:error, Jason.encode!(rejection)}
    end
  end

  def call(_, _, _),
    do: {:error, "update_memory takes target (user or memory) and operations"}
end
