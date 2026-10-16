defmodule BurpeeTrainerWeb.HomeAdjustmentTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.HomeAdjustment

  test "submitted trimmed text is authoritative" do
    assert {:ok, {:start, ""}} = HomeAdjustment.operation(" \n\t ")
    assert {:ok, {:update, "Less rest"}} = HomeAdjustment.operation(" Less rest ")
    assert {:error, _} = HomeAdjustment.operation(String.duplicate("x", 501))
  end

  test "grapheme and byte bounds are independent and changesets preserve whitespace" do
    text = String.duplicate("e\u0301", 500)
    assert {:ok, {:update, ^text}} = HomeAdjustment.operation(text)
    assert {:error, :invalid_instruction} = HomeAdjustment.operation(String.duplicate("👨‍👩‍👧‍👦", 200))

    for invalid <- [nil, 1, %{}, []],
        do: assert({:error, :invalid_instruction} = HomeAdjustment.operation(invalid))

    changeset = HomeAdjustment.changeset(%HomeAdjustment{}, %{"instruction" => "  "})
    assert Ecto.Changeset.get_field(changeset, :instruction) == "  "
  end
end
