defmodule BurpeeTrainer.ReplayProvider do
  @moduledoc "Req.Test replay of explicit response files; exhaustion is a test failure. No capture provenance is implied."

  def stub(name, path) do
    responses = path |> File.read!() |> Jason.decode!()

    unless is_list(responses) and Enum.all?(responses, &is_map/1),
      do: raise(ArgumentError, "Replay file must be an array of provider response objects")

    {:ok, counter} = ExUnit.Callbacks.start_supervised({Agent, fn -> responses end})

    Req.Test.stub(name, fn conn ->
      case Agent.get_and_update(counter, fn
             [response | rest] -> {{:ok, response}, rest}
             [] -> {:exhausted, []}
           end) do
        {:ok, response} -> Req.Test.json(conn, response)
        :exhausted -> raise ExUnit.AssertionError, message: "Replay exhausted: #{path}"
      end
    end)
  end
end
