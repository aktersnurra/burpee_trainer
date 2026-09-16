defmodule BurpeeTrainer.TestAuthoringProviderPlug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    schema = get_in(Jason.decode!(body), ["response_format", "json_schema", "name"])

    response =
      Agent.get_and_update(opts[:counter], fn %{responses: responses, calls: calls} = state ->
        {Map.fetch!(responses, schema), %{state | calls: calls ++ [schema]}}
      end)

    content = Jason.encode!(response)
    envelope = %{"choices" => [%{"message" => %{"content" => content}}]}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(envelope))
  end
end
