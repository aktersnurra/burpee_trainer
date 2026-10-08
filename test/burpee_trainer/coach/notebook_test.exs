defmodule BurpeeTrainer.Coach.NotebookTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.Notebook

  test "bounded owned notebook uses compare-and-swap" do
    scope = scope_fixture()
    assert %{body: "", updated_at: nil} = Notebook.get(scope)
    assert {:ok, nb} = Notebook.write(scope, "Prefers short sets.", nil)
    assert {:error, :too_long} = Notebook.write(scope, String.duplicate("x", 4001), nb.updated_at)
    assert {:ok, _} = Notebook.write(scope, "Owner edit.", nb.updated_at)
    assert {:error, :stale_notebook} = Notebook.write(scope, "Agent rewrite.", nb.updated_at)
    assert Notebook.get(scope).body == "Owner edit."
    assert Notebook.get(scope_fixture()).body == ""
  end
end
