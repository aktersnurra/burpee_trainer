defmodule BurpeeTrainer.Coach.Memory.OpsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.Coach.Memory.Ops

  defp notes(texts),
    do: texts |> Enum.with_index(1) |> Enum.map(fn {t, i} -> %{id: i, text: t} end)

  test "adds new facts, forgets known ones, and replaces one with another" do
    current = notes(["Trains at 7:00", "Left knee sore after jumps"])

    assert Ops.plan(current, [
             %{"op" => "add", "text" => "  Prefers  unbroken sets "},
             %{"op" => "forget", "id" => 2},
             %{"op" => "replace", "id" => 1, "text" => "Trains at 18:00"}
           ]) == %{add: ["Prefers unbroken sets", "Trains at 18:00"], forget: [2, 1]}
  end

  test "ignores repeats, unknown ids, empty or long text, and anything past five ops" do
    current = notes(["Trains at 7:00"])

    assert Ops.plan(current, [
             %{"op" => "add", "text" => "trains AT 7:00"},
             %{"op" => "forget", "id" => 99},
             %{"op" => "add", "text" => " "},
             %{"op" => "add", "text" => String.duplicate("x", 161)},
             %{"op" => "replace", "id" => 1, "text" => ""},
             %{"op" => "add", "text" => "Sixth op"}
           ]) == %{add: [], forget: []}

    # The owner reads every note, so none names a level by its internal id.
    assert Ops.plan(current, [
             %{"op" => "add", "text" => "Holds level_1a"}
           ]) == %{add: [], forget: []}
  end

  property "the memory stays within twenty distinct notes, and only known notes are forgotten" do
    check all(
            texts <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 12), max_length: 25),
            ops <-
              list_of(
                one_of([
                  fixed_map(%{
                    "op" => constant("add"),
                    "text" => string(:printable, max_length: 20)
                  }),
                  fixed_map(%{"op" => constant("forget"), "id" => integer(0..30)}),
                  fixed_map(%{
                    "op" => constant("replace"),
                    "id" => integer(0..30),
                    "text" => string(:alphanumeric, max_length: 20)
                  })
                ]),
                max_length: 8
              )
          ) do
      current = notes(Enum.uniq_by(texts, &String.downcase/1))
      %{add: add, forget: forget} = Ops.plan(current, ops)

      assert Enum.all?(forget, fn id -> Enum.any?(current, &(&1.id == id)) end)
      assert forget == Enum.uniq(forget)

      kept = current |> Enum.reject(&(&1.id in forget)) |> Enum.map(& &1.text)
      after_texts = kept ++ add
      assert length(after_texts) <= 20
      assert length(add) <= 5
      keys = Enum.map(add, &String.downcase/1)
      assert keys == Enum.uniq(keys)
      assert Enum.all?(add, &(&1 != "" and String.length(&1) <= 160))
    end
  end
end
