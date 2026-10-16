defmodule BurpeeTrainer.Evals.Recorder do
  @moduledoc "Captures provider response JSON only, never requests, headers or credentials."

  def attach(%Req.Request{} = req, counter) do
    Req.Request.append_response_steps(req,
      eval_capture: fn {request, response} ->
        body =
          case response.body do
            body when is_map(body) -> {:ok, body}
            body when is_binary(body) -> Jason.decode(body)
            _ -> :error
          end

        case body do
          {:ok, body} when is_map(body) -> Agent.update(counter, &(&1 ++ [body]))
          _ -> :ok
        end

        {request, response}
      end
    )
  end

  def responses(counter), do: Agent.get(counter, & &1)

  def write!(root, id, responses, provenance) do
    unless Regex.match?(~r/\A[a-z0-9_]+\z/, id), do: raise(ArgumentError, "Invalid recording ID")
    File.mkdir_p!(root)
    File.write!(Path.join(root, id <> ".json"), Jason.encode!(responses, pretty: true) <> "\n")

    File.write!(
      Path.join(root, id <> ".provenance.json"),
      Jason.encode!(provenance, pretty: true) <> "\n"
    )
  end
end
