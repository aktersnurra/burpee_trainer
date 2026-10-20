defmodule BurpeeTrainer.AnalyticsProviderPlug do
  @moduledoc false
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, {agent, owner}) do
    {:ok, body, conn} = read_body(conn)
    request = Jason.decode!(body)
    send(owner, {:analytics_request, request})
    response = Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
    response = if is_function(response, 1), do: response.(request), else: response

    body =
      if Map.has_key?(response, "answers"),
        do: response,
        else: %{
          "choices" => [%{"message" => %{"content" => Jason.encode!(response)}}],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 10}
        }

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  def request(responses) do
    agent = ExUnit.Callbacks.start_supervised!({Agent, fn -> responses end}, id: make_ref())
    Req.new(plug: {__MODULE__, {agent, self()}})
  end
end
