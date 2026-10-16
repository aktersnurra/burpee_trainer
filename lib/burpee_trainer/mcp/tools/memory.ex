defmodule BurpeeTrainer.Mcp.Tools.ListMemory do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Memory, Tool}

  def name, do: "list_memory"

  def description,
    do:
      "The coach's notes about the athlete, oldest first, shared with the app's own coach. " <>
        "Use their ids to forget or replace one."

  def schema, do: Tool.object(%{}, [])

  def call(scope, args, _) when is_map(args) and map_size(args) == 0,
    do:
      {:ok,
       %{
         "notes" =>
           Enum.map(Memory.list(scope), fn note ->
             %{
               "id" => note.id,
               "text" => note.text,
               "noted_on" => Date.to_iso8601(DateTime.to_date(note.inserted_at))
             }
           end)
       }}

  def call(_, _, _), do: {:error, "list_memory takes no arguments"}
end

defmodule BurpeeTrainer.Mcp.Tools.UpdateMemory do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Memory, Tool}
  alias BurpeeTrainer.Coach.Memory.Ops

  @max_ops 5

  def name, do: "update_memory"

  def description,
    do:
      "Change the coach's notes about the athlete, shared with the app's own coach; the " <>
        "athlete sees each change in the app. A note is one plain sentence under 160 " <>
        "characters about a lasting fact: when they train, soreness, likes and dislikes, what " <>
        "they train for. Not results (reps, times, levels), which are kept elsewhere, and no " <>
        "internal names such as six_count (write six-count). At most #{@max_ops} ops; notes " <>
        "past 20 push out the oldest. Returns what changed and how many ops were ignored."

  def schema do
    op = %{
      "type" => "object",
      "properties" => %{
        "op" => %{"type" => "string", "enum" => ~w[add forget replace]},
        "id" => %{"type" => "integer", "description" => "The note to forget or replace."},
        "text" => %{
          "type" => "string",
          "maxLength" => 160,
          "description" => "The note to add, or the replacement."
        }
      },
      "required" => ["op"],
      "additionalProperties" => false
    }

    Tool.object(
      %{"ops" => %{"type" => "array", "items" => op, "minItems" => 1, "maxItems" => @max_ops}},
      ["ops"]
    )
  end

  def call(scope, %{"ops" => [_ | _] = ops} = args, _) when map_size(args) == 1 do
    if Enum.all?(ops, &is_map/1) do
      ignored = ignored(scope, ops)

      case Memory.apply_ops(scope, ops) do
        {:ok, changes} ->
          {:ok,
           %{
             "changes" => Enum.map(changes, &%{"kind" => to_string(&1.kind), "text" => &1.text}),
             "ignored" => ignored
           }}

        {:error, _} ->
          {:error, "the memory could not be changed; nothing was saved"}
      end
    else
      {:error, "each op is an object"}
    end
  end

  def call(_, _, _), do: {:error, "update_memory takes ops: a list of 1 to #{@max_ops} ops"}

  # An op is ignored when adding it to the ops before it changes nothing the guard plans.
  defp ignored(scope, ops) do
    notes = scope |> Memory.list() |> Enum.map(&Map.take(&1, [:id, :text]))
    counted = Enum.take(ops, @max_ops)

    effective =
      1..length(counted)
      |> Enum.count(fn n ->
        Ops.plan(notes, Enum.take(counted, n)) != Ops.plan(notes, Enum.take(counted, n - 1))
      end)

    length(ops) - effective
  end
end
