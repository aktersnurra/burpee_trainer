defmodule BurpeeTrainerWeb.ParamsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainerWeb.Params

  describe "index/1" do
    test "parses a non-negative integer" do
      assert Params.index("0") == {:ok, 0}
      assert Params.index("12") == {:ok, 12}
    end

    test "accepts an integer that is already parsed" do
      assert Params.index(7) == {:ok, 7}
    end

    test "rejects values that are not a whole non-negative number" do
      for value <- ["", "abc", "1.5", "-3", "12x", " 4", nil, %{}] do
        assert Params.index(value) == :error, "expected #{inspect(value)} to be rejected"
      end
    end
  end

  describe "known_atom/2" do
    test "converts a value that is in the allow-list" do
      assert Params.known_atom("six_count", ~w(six_count navy_seal)) ==
               {:ok, :six_count}
    end

    test "rejects a value outside the allow-list" do
      assert Params.known_atom("nope", ~w(six_count navy_seal)) == :error
    end

    test "rejects a non-binary value" do
      assert Params.known_atom(nil, ~w(six_count)) == :error
      assert Params.known_atom(:six_count, ~w(six_count)) == :error
    end
  end
end
