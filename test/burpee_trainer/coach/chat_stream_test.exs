defmodule BurpeeTrainer.Coach.ChatStreamTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.Coach.{ChatStream, PartialJson}

  defp sse(chunks),
    do: Enum.map_join(chunks, &"data: #{Jason.encode!(&1)}\n\n") <> "data: [DONE]\n\n"

  defp content(text), do: %{"choices" => [%{"delta" => %{"content" => text}}]}

  defp read(body, sizes) do
    {stream, _rest} =
      Enum.reduce_while(Stream.cycle(sizes), {ChatStream.new(), body}, fn
        _size, {stream, ""} ->
          {:halt, {stream, ""}}

        size, {stream, rest} ->
          take = min(size, byte_size(rest))
          <<chunk::binary-size(^take), rest::binary>> = rest
          {stream, _grew?} = ChatStream.feed(stream, chunk)
          {:cont, {stream, rest}}
      end)

    stream
  end

  property "however the body is split, the stream reads as the whole answer" do
    check all(
            pieces <- list_of(string(:printable, max_length: 12), min_length: 1, max_length: 8),
            sizes <- list_of(integer(1..40), min_length: 1, max_length: 6)
          ) do
      body =
        sse(
          [%{"choices" => [%{"delta" => %{"reasoning" => "thinking it over"}}]}] ++
            Enum.map(pieces, &content/1) ++ [%{"choices" => [], "usage" => %{"cost" => 0.1}}]
        )

      assert {:ok, %{"choices" => [%{"message" => message}], "usage" => %{"cost" => 0.1}}} =
               body |> read(sizes) |> ChatStream.envelope()

      assert message["content"] == Enum.join(pieces)
      refute Map.has_key?(message, "tool_calls")
    end
  end

  test "thinking is never part of the answer, and keep-alive comments are skipped" do
    body =
      ": OPENROUTER PROCESSING\n\n" <>
        sse([
          %{"choices" => [%{"delta" => %{"reasoning" => "Let me think"}}]},
          content("Rest "),
          content("today.")
        ])

    {stream, _} = ChatStream.feed(ChatStream.new(), body)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "Rest today."}}]}} =
             ChatStream.envelope(stream)
  end

  test "tool calls arrive in pieces and are put back together in order" do
    body =
      sse([
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 1,
                    "id" => "b",
                    "function" => %{"name" => "goals", "arguments" => "{}"}
                  },
                  %{
                    "index" => 0,
                    "id" => "a",
                    "function" => %{"name" => "history", "arguments" => "{\"we"}
                  }
                ]
              }
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "eks\":4}"}}]
              }
            }
          ]
        }
      ])

    {stream, _} = ChatStream.feed(ChatStream.new(), body)
    {:ok, %{"choices" => [%{"message" => message}]}} = ChatStream.envelope(stream)

    assert [
             %{"id" => "a", "function" => %{"name" => "history", "arguments" => ~s({"weeks":4})}},
             %{"id" => "b", "function" => %{"name" => "goals", "arguments" => "{}"}}
           ] = message["tool_calls"]

    assert message["content"] == nil
  end

  test "a stream cut short or carrying an error has no answer" do
    {cut, _} = ChatStream.feed(ChatStream.new(), "data: #{Jason.encode!(content("Hal"))}\n\n")
    assert ChatStream.envelope(cut) == :error

    {failed, _} =
      ChatStream.feed(ChatStream.new(), sse([content("Hi"), %{"error" => %{"message" => "x"}}]))

    assert ChatStream.envelope(failed) == :error
  end

  property "the first string field reads as a prefix of itself at every point of its JSON" do
    check all(
            text <- string(:utf8, max_length: 40),
            other <- string(:printable, max_length: 10)
          ) do
      json =
        Jason.encode!(%Jason.OrderedObject{values: [{"reply", text}, {"name", other}]},
          escape: :unicode_safe
        )

      prefixes = for n <- 0..String.length(json), do: String.slice(json, 0, n)
      read = Enum.map(prefixes, &PartialJson.first_string(&1, "reply"))

      assert List.last(read) == text

      for value <- read, value != nil do
        assert String.starts_with?(text, value)
      end
    end
  end

  test "whitespace between tokens is allowed, and another first field reads as nothing" do
    assert PartialJson.first_string(~s(\n{ "reply" : " Rest), "reply") == " Rest"
    assert PartialJson.first_string(~s({"name":"x","reply":"Rest"}), "reply") == nil
    assert PartialJson.first_string(~s({"rep), "reply") == nil
  end
end
