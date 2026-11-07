defmodule BurpeeTrainer.Coach.PartialJson do
  @moduledoc """
  Pure: the text so far of a string field while the JSON object holding it is still being
  written, so a reply can be shown word by word before the object is whole.

  The field must be the object's first property, as the schemas that stream put it.
  """

  @doc """
  The decoded prefix of the string `key` opening `json`, or nil while it has not begun.
  An escape cut off at the end is left for the next call.
  """
  @spec first_string(String.t(), String.t()) :: String.t() | nil
  def first_string(json, key) when is_binary(json) and is_binary(key) do
    case tokens(json, ["{", Jason.encode!(key), ":", "\""]) do
      {:ok, value} -> decode(value, [])
      :not_yet -> nil
    end
  end

  # `{ "key" : "`, with any whitespace between the tokens but none inside them.
  defp tokens(rest, []), do: {:ok, rest}

  defp tokens(json, [token | tokens]) do
    rest = strip_space(json)
    size = byte_size(token)

    case rest do
      <<^token::binary-size(^size), rest::binary>> -> tokens(rest, tokens)
      _ -> :not_yet
    end
  end

  defp strip_space(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r],
    do: strip_space(rest)

  defp strip_space(rest), do: rest

  defp decode("", acc), do: finish(acc)
  defp decode("\"" <> _closed, acc), do: finish(acc)

  defp decode("\\u" <> <<hex::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(hex, 16) do
      {high, ""} when high in 0xD800..0xDBFF -> low_surrogate(high, rest, acc)
      {code, ""} when code not in 0xDC00..0xDFFF -> decode(rest, [<<code::utf8>> | acc])
      _ -> finish(acc)
    end
  end

  defp decode("\\" <> <<escape, rest::binary>>, acc) when escape in ~c"\"\\/bfnrt",
    do: decode(rest, [unescape(escape) | acc])

  defp decode("\\" <> _incomplete, acc), do: finish(acc)
  defp decode(<<char::utf8, rest::binary>>, acc), do: decode(rest, [<<char::utf8>> | acc])
  defp decode(_invalid, acc), do: finish(acc)

  # A character outside the first plane is written as two escapes; until both are in, it waits.
  defp low_surrogate(high, "\\u" <> <<hex::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(hex, 16) do
      {low, ""} when low in 0xDC00..0xDFFF ->
        code = 0x10000 + Bitwise.bsl(high - 0xD800, 10) + (low - 0xDC00)
        decode(rest, [<<code::utf8>> | acc])

      _ ->
        finish(acc)
    end
  end

  defp low_surrogate(_high, _incomplete, acc), do: finish(acc)

  defp unescape(?b), do: "\b"
  defp unescape(?f), do: "\f"
  defp unescape(?n), do: "\n"
  defp unescape(?r), do: "\r"
  defp unescape(?t), do: "\t"
  defp unescape(char), do: <<char>>

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
