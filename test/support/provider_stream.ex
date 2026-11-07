defmodule BurpeeTrainer.ProviderStream do
  @moduledoc """
  Answers a test's provider request the way the provider would: as server-sent events when
  the request asked to stream, else as one JSON envelope. The answer is split into small
  pieces, so a streaming reader sees it grow.
  """

  import Plug.Conn

  @doc "Sends `envelope` (a chat completion) as the request asked for it."
  def reply(conn, envelope, body \\ nil) do
    body =
      case body do
        nil ->
          {:ok, read, _conn} = read_body(conn)
          read

        given ->
          given
      end

    if match?(%{"stream" => true}, Jason.decode!(body)),
      do: conn |> put_resp_content_type("text/event-stream") |> send_resp(200, sse(envelope)),
      else: Req.Test.json(conn, envelope)
  end

  @doc "The `Req.Response` an adapter returns for `request`, as it asked for `envelope`."
  def response(%Req.Request{} = request, envelope, status \\ 200) do
    streamed? = match?(%{"stream" => true}, Jason.decode!(IO.iodata_to_binary(request.body)))

    body =
      if streamed? and status == 200, do: sse(envelope), else: Jason.encode!(envelope)

    %Req.Response{status: status, body: body}
  end

  @doc "A chat completion envelope as the events that stream it."
  def sse(%{"choices" => [%{"message" => message} | _]} = envelope) do
    content =
      case message["content"] do
        text when is_binary(text) ->
          text |> String.codepoints() |> Enum.chunk_every(7) |> Enum.map(&Enum.join/1)

        _none ->
          []
      end

    calls =
      message
      |> Map.get("tool_calls", [])
      |> Enum.with_index(fn call, index -> Map.put(call, "index", index) end)

    events =
      [%{"choices" => [%{"delta" => %{"role" => "assistant", "reasoning" => "Thinking."}}]}] ++
        Enum.map(content, &%{"choices" => [%{"delta" => %{"content" => &1}}]}) ++
        if(calls == [], do: [], else: [%{"choices" => [%{"delta" => %{"tool_calls" => calls}}]}]) ++
        [%{"choices" => [], "usage" => Map.get(envelope, "usage", %{})}]

    Enum.map_join(events, &"data: #{Jason.encode!(&1)}\n\n") <> "data: [DONE]\n\n"
  end
end
