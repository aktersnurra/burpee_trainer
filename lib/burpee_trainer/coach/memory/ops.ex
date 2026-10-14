defmodule BurpeeTrainer.Coach.Memory.Ops do
  @moduledoc """
  Pure: what the coach asked to change in its memory, made safe. `plan/2` takes the active
  notes, oldest first, and the model's ops, and returns what to add and which notes to
  forget:

    * `add` keeps a trimmed note of up to #{160} characters that no active note already says
      (ignoring case and spacing) and that names nothing by an internal id, since the owner
      reads every note (`Voice.internal_id/1`);
    * `forget` takes an active note's id; anything else is ignored;
    * `replace` is forget and add together, or nothing when its text would not be kept;
    * at most #{5} ops count, and past #{20} notes the oldest are forgotten.
  """

  @max_text 160
  @max_ops 5
  @max_notes 20

  @type note :: %{id: pos_integer(), text: String.t()}
  @type plan :: %{add: [String.t()], forget: [pos_integer()]}

  @spec plan([note()], [map()]) :: plan()
  def plan(notes, ops) when is_list(notes) and is_list(ops) do
    ids = MapSet.new(notes, & &1.id)

    %{add: add, forget: forget} =
      ops
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_ops)
      |> Enum.reduce(%{add: [], forget: []}, fn op, acc -> step(op, acc, notes, ids) end)

    add = Enum.reverse(add)
    forget = Enum.reverse(forget)
    kept = Enum.reject(notes, &(&1.id in forget))
    over = length(kept) + length(add) - @max_notes
    oldest = kept |> Enum.take(max(over, 0)) |> Enum.map(& &1.id)

    %{add: add, forget: forget ++ oldest}
  end

  defp step(%{"op" => "add", "text" => text}, acc, notes, _ids) do
    case keep(text, notes, acc) do
      nil -> acc
      text -> %{acc | add: [text | acc.add]}
    end
  end

  defp step(%{"op" => "forget", "id" => id}, acc, _notes, ids) do
    if MapSet.member?(ids, id) and id not in acc.forget,
      do: %{acc | forget: [id | acc.forget]},
      else: acc
  end

  defp step(%{"op" => "replace", "id" => id, "text" => text}, acc, notes, ids) do
    others = Enum.reject(notes, &(&1.id == id))

    with true <- MapSet.member?(ids, id) and id not in acc.forget,
         text when is_binary(text) <- keep(text, others, acc) do
      %{add: [text | acc.add], forget: [id | acc.forget]}
    else
      _ -> acc
    end
  end

  defp step(_op, acc, _notes, _ids), do: acc

  defp keep(text, notes, acc) when is_binary(text) do
    text = text |> String.split() |> Enum.join(" ")
    said = MapSet.new(Enum.map(notes, & &1.text) ++ acc.add, &key/1)

    cond do
      text == "" -> nil
      String.length(text) > @max_text -> nil
      MapSet.member?(said, key(text)) -> nil
      BurpeeTrainer.Coach.Voice.internal_id(text) -> nil
      true -> text
    end
  end

  defp keep(_text, _notes, _acc), do: nil

  defp key(text), do: text |> String.downcase() |> String.split() |> Enum.join(" ")
end
