defmodule BurpeeTrainer.LoggingConfigTest do
  use ExUnit.Case, async: true

  test "production Logger writes bounded, rotating runtime logs in the jail" do
    config = Config.Reader.read!("config/prod.exs")
    handler = config |> Keyword.fetch!(:logger) |> Keyword.fetch!(:default_handler)
    options = Keyword.fetch!(handler, :config)

    assert options[:file] == ~c"/var/log/burpee/trainer-runtime.log"
    assert options[:max_no_bytes] == 10_000_000
    assert options[:max_no_files] == 5
  end
end
