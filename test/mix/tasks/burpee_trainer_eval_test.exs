defmodule Mix.Tasks.BurpeeTrainer.EvalTest do
  use BurpeeTrainer.DataCase, async: false

  test "task rejects absent cap before starting an evaluation" do
    assert_raise Mix.Error, ~r/--max-calls is required/, fn ->
      Mix.Tasks.BurpeeTrainer.Eval.run(["--suite", "authoring"])
    end
  end
end
