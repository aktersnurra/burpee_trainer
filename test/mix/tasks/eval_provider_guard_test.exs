defmodule BurpeeTrainer.Evals.ProviderGuardTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Evals.ProviderGuard

  test "nil and malformed requests never authorize test transport" do
    for request <- [nil, %{}, :invalid],
        url <- ["https://provider.test/v1", "https://openrouter.ai/v1"] do
      assert_raise Mix.Error, fn -> ProviderGuard.check!(:test, [url: url], request) end
    end
  end

  test "test evals require BOTH actual Req.Test plug and a test-only URL" do
    stub = Req.new(plug: {Req.Test, __MODULE__})
    assert :ok = ProviderGuard.check!(:test, [url: "https://provider.test/v1"], stub)

    assert_raise Mix.Error, fn ->
      ProviderGuard.check!(:test, [url: "https://provider.test/v1"], Req.new())
    end

    assert_raise Mix.Error, fn ->
      ProviderGuard.check!(:test, [url: "https://openrouter.ai/v1"], stub)
    end

    assert_raise Mix.Error, fn -> ProviderGuard.check!(:test, [url: nil], stub) end
    assert :ok = ProviderGuard.check!(:dev, [url: "https://openrouter.ai/v1"], Req.new())
  end
end
