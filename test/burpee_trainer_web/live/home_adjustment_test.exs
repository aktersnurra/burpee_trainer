defmodule BurpeeTrainerWeb.HomeAdjustmentTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.HomeAdjustment

  test "the box's text is kept as typed, whitespace and all" do
    changeset = HomeAdjustment.changeset(%HomeAdjustment{}, %{"instruction" => "  "})
    assert Ecto.Changeset.get_field(changeset, :instruction) == "  "
  end
end
