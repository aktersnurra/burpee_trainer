defmodule BurpeeTrainer.Workouts.GzipText do
  @moduledoc """
  Text stored gzipped. Pose-trace JSON compresses about 6.5 times; a 20-minute camera
  session would otherwise take about 120 MB. Loads plain text too, which no JSON payload
  can be confused with (gzip starts with bytes 31, 139; JSON with `{`).
  """
  use Ecto.Type

  def type, do: :binary

  def cast(text) when is_binary(text), do: {:ok, text}
  def cast(_), do: :error

  def dump(text) when is_binary(text), do: {:ok, :zlib.gzip(text)}
  def dump(_), do: :error

  def load(<<31, 139, _::binary>> = gzipped), do: {:ok, :zlib.gunzip(gzipped)}
  def load(text) when is_binary(text), do: {:ok, text}
  def load(_), do: :error
end
