defmodule BurpeeTrainer.Coach.Tool do
  @moduledoc "Scoped agent tool definitions and validation. Invalid arguments never reach effects."
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: map()
  @callback call(BurpeeTrainer.Accounts.Scope.t(), map(), map()) ::
              {:ok, map()} | {:ok, map(), map()} | {:error, String.t()}
  def definition(module),
    do: %{name: module.name(), description: module.description(), schema: module.schema()}

  def object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
end
