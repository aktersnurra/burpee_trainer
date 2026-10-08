defmodule BurpeeTrainer.Evals.OptionsTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Evals.Options

  test "explicit positive hard budget and known suite required" do
    for args <- [
          [],
          ["--max-calls", "0"],
          ["--max-calls", "-1"],
          ["--max-calls", "oops"],
          ["--max-calls", "2", "--suite", "../unsafe"],
          ["--max-calls", "1", "--unknown"],
          ["--max-calls", "1", "--max-calls", "2"]
        ] do
      assert_raise Mix.Error, fn -> Options.parse!(args) end
    end

    assert %{max_calls: 4, suite: "authoring", only: "navy_seal_80", record: true} =
             Options.parse!(["--max-calls", "4", "--only", "navy_seal_80", "--record"])
  end
end
