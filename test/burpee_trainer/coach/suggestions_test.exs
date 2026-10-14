defmodule BurpeeTrainer.Coach.SuggestionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.Coach.Suggestions

  test "keeps up to three short, distinct, non-empty phrases, trimmed" do
    assert Suggestions.clean([
             " Make Thursday harder ",
             "",
             "make thursday harder",
             "My knee is sore",
             "Move it to mornings",
             "A fourth"
           ]) ==
             ["Make Thursday harder", "My knee is sore", "Move it to mornings"]
  end

  test "drops what is not a phrase or too long to tap" do
    assert Suggestions.clean([nil, 3, String.duplicate("a", 61), "Fine"]) == ["Fine"]
    assert Suggestions.clean(nil) == []
    assert Suggestions.clean("not a list") == []
  end

  property "whatever the model sends, at most three short strings come back" do
    check all(
            items <-
              list_of(one_of([string(:printable, max_length: 90), integer(), constant(nil)]))
          ) do
      cleaned = Suggestions.clean(items)
      assert length(cleaned) <= 3

      assert Enum.all?(
               cleaned,
               &(is_binary(&1) and String.trim(&1) != "" and String.length(&1) <= 60)
             )
    end
  end
end
