defmodule BurpeeTrainer.ReplayProviderTest do
  use ExUnit.Case, async: true

  test "serves fixture responses in order and fails closed when exhausted" do
    path = Path.join(System.tmp_dir!(), "replay-#{Ecto.UUID.generate()}.json")
    File.write!(path, Jason.encode!([%{"id" => "one"}, %{"id" => "two"}]), [:exclusive])
    on_exit(fn -> File.rm!(path) end)
    BurpeeTrainer.ReplayProvider.stub(__MODULE__, path)

    assert Req.post!("https://provider.test", plug: {Req.Test, __MODULE__}).body == %{
             "id" => "one"
           }

    assert Req.post!("https://provider.test", plug: {Req.Test, __MODULE__}).body == %{
             "id" => "two"
           }

    assert_raise ExUnit.AssertionError, fn ->
      Req.post!("https://provider.test", plug: {Req.Test, __MODULE__})
    end
  end
end
