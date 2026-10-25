defmodule BurpeeTrainerWeb.PoseUploadBodyReader do
  @moduledoc "Bounded request gzip decoding for the pose-upload endpoint only."
  @max_bytes 512 * 1024

  def read_body(%Plug.Conn{request_path: "/api/session-pose-traces"} = conn, opts) do
    opts = Keyword.merge(opts, length: @max_bytes, read_length: 64 * 1024)

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} when byte_size(body) <= @max_bytes -> decode(conn, body)
      {:ok, _body, conn} -> {:more, "", conn}
      other -> other
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp decode(conn, body) do
    case Plug.Conn.get_req_header(conn, "content-encoding") do
      [] -> {:ok, body, conn}
      ["identity"] -> {:ok, body, conn}
      ["gzip"] -> inflate(body, conn)
      _unsupported -> {:error, :unsupported_encoding}
    end
  end

  defp inflate(body, conn) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, 31)

      case inflate_parts(stream, body, [], 0) do
        {:ok, decoded} ->
          # Checks the gzip trailer too; a truncated stream must not look successful.
          :ok = :zlib.inflateEnd(stream)
          {:ok, decoded, conn}

        :too_large ->
          {:more, "", conn}
      end
    rescue
      ErlangError -> {:error, :invalid_gzip}
    after
      :zlib.close(stream)
    end
  end

  defp inflate_parts(stream, input, parts, bytes) do
    {status, output} = :zlib.safeInflate(stream, input)
    bytes = bytes + IO.iodata_length(output)

    cond do
      bytes > @max_bytes -> :too_large
      status == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([output | parts]))}
      true -> inflate_parts(stream, <<>>, [output | parts], bytes)
    end
  end
end
