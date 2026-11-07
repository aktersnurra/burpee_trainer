defmodule BurpeeTrainer.Coach.ChatStream do
  @moduledoc """
  Pure: a chat completion streamed as server-sent events, read as its bytes arrive.

  `feed/2` takes the next chunk of the response body, however the network split it, and
  `envelope/1` gives back the completion as the provider would have sent it whole, so it is
  checked the same way. The model's reasoning is never collected: only the answer is shown.
  A stream that ends without `[DONE]`, or that carries an error, has no envelope.
  """

  defstruct pending: "",
            data: [],
            content: nil,
            refusal: nil,
            tool_calls: %{},
            usage: nil,
            done?: false,
            error?: false

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Reads `chunk`; the answer so far is `content`, and whether it grew."
  @spec feed(t(), binary()) :: {t(), boolean()}
  def feed(%__MODULE__{} = stream, chunk) when is_binary(chunk) do
    {lines, pending} = split_lines(stream.pending <> chunk)
    before = stream.content
    stream = Enum.reduce(lines, %{stream | pending: pending}, &line/2)
    {stream, stream.content != before}
  end

  @doc "The completion as one chat envelope, once the stream finished cleanly."
  @spec envelope(t()) :: {:ok, map()} | :error
  def envelope(%__MODULE__{done?: true, error?: false} = stream) do
    calls =
      stream.tool_calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {_index, call} ->
        %{
          "id" => call.id,
          "type" => "function",
          "function" => %{"name" => call.name, "arguments" => call.arguments}
        }
      end)

    message =
      %{"content" => stream.content, "refusal" => stream.refusal}
      |> then(&if(calls == [], do: &1, else: Map.put(&1, "tool_calls", calls)))

    {:ok, %{"choices" => [%{"message" => message}], "usage" => stream.usage || %{}}}
  end

  def envelope(%__MODULE__{}), do: :error

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.map(Enum.drop(parts, -1), &String.trim_trailing(&1, "\r")), List.last(parts)}
  end

  # A blank line ends an event; a line starting with a colon is a comment (keep-alives).
  defp line("", stream), do: event(stream)
  defp line(":" <> _comment, stream), do: stream
  defp line("data:" <> data, stream), do: %{stream | data: [trim_space(data) | stream.data]}
  defp line(_field, stream), do: stream

  defp trim_space(" " <> data), do: data
  defp trim_space(data), do: data

  defp event(%{data: []} = stream), do: stream

  defp event(stream) do
    data = stream.data |> Enum.reverse() |> Enum.join("\n")
    stream = %{stream | data: []}

    case data do
      "[DONE]" ->
        %{stream | done?: true}

      json ->
        case Jason.decode(json) do
          {:ok, %{"error" => _}} -> %{stream | error?: true}
          {:ok, %{} = chunk} -> chunk(stream, chunk)
          _invalid -> %{stream | error?: true}
        end
    end
  end

  defp chunk(stream, chunk) do
    stream =
      case chunk["usage"] do
        %{} = usage -> %{stream | usage: usage}
        _none -> stream
      end

    case chunk["choices"] do
      [%{"finish_reason" => "error"} | _] -> %{stream | error?: true}
      [%{"delta" => %{} = delta} | _] -> delta(stream, delta)
      _other -> stream
    end
  end

  # `reasoning` and `reasoning_details` are the model thinking; they are not kept.
  defp delta(stream, delta) do
    stream
    |> append(:content, delta["content"])
    |> append(:refusal, delta["refusal"])
    |> calls(delta["tool_calls"])
  end

  defp append(stream, key, text) when is_binary(text),
    do: Map.update!(stream, key, &((&1 || "") <> text))

  defp append(stream, _key, _text), do: stream

  defp calls(stream, [_ | _] = calls), do: Enum.reduce(calls, stream, &call/2)
  defp calls(stream, _none), do: stream

  defp call(%{"index" => index} = part, stream) when is_integer(index) do
    function = Map.get(part, "function") || %{}
    current = Map.get(stream.tool_calls, index, %{id: nil, name: nil, arguments: ""})

    call = %{
      id: part["id"] || current.id,
      name: function["name"] || current.name,
      arguments: current.arguments <> (function["arguments"] || "")
    }

    %{stream | tool_calls: Map.put(stream.tool_calls, index, call)}
  end

  defp call(_part, stream), do: %{stream | error?: true}
end
