defmodule BurpeeTrainerWeb.ReplyStream do
  @moduledoc """
  A reply as the coach writes it. The provider reports the whole text so far each time it
  grows; the browser is sent only the piece that is new, as an item of a LiveView stream, so
  a long reply does not cross the wire again with every word.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4, stream_insert: 3]

  @doc "An empty stream, before anything is written."
  def initialize(socket, name),
    do: socket |> stream(name, [], dom_id: &"#{name}-#{&1.id}") |> assign(sent(name), nil)

  @doc "Shows `text`, the reply so far; `nil` when nothing is being written."
  def show(socket, name, text) do
    case {socket.assigns[sent(name)], text} do
      {same, same} ->
        socket

      {_shown, nil} ->
        socket |> stream(name, [], reset: true) |> assign(sent(name), nil)

      {shown, text} when is_binary(text) ->
        socket |> grow(name, shown || "", text) |> assign(sent(name), text)
    end
  end

  defp grow(socket, name, shown, text) do
    if String.starts_with?(text, shown) do
      piece = binary_part(text, byte_size(shown), byte_size(text) - byte_size(shown))
      stream_insert(socket, name, %{id: byte_size(shown), text: piece})
    else
      stream(socket, name, [%{id: 0, text: text}], reset: true)
    end
  end

  defp sent(name), do: :"#{name}_sent"
end
