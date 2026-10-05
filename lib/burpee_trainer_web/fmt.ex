defmodule BurpeeTrainerWeb.Fmt do
  @moduledoc """
  Small presentation helpers — duration formatting, burpee-type labels,
  etc. Kept separate from core_components to keep that module focused on
  UI primitives.
  """

  @doc """
  Format a duration in seconds as `M:SS` or `H:MM:SS`.
  """
  @spec duration_sec(number | nil) :: String.t()
  def duration_sec(nil), do: "—"

  def duration_sec(seconds) when is_number(seconds) do
    total = round(seconds)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)
    secs = rem(total, 60)

    cond do
      hours > 0 ->
        :io_lib.format("~b:~2..0b:~2..0b", [hours, minutes, secs]) |> IO.iodata_to_binary()

      true ->
        :io_lib.format("~b:~2..0b", [minutes, secs]) |> IO.iodata_to_binary()
    end
  end

  @doc """
  Human-readable label for a burpee_type enum.
  """
  @spec burpee_type(atom | String.t() | nil) :: String.t()
  def burpee_type(:six_count), do: "6-Count"
  def burpee_type(:navy_seal), do: "Navy SEAL"
  def burpee_type("six_count"), do: "6-Count"
  def burpee_type("navy_seal"), do: "Navy SEAL"
  def burpee_type(_), do: "—"

  @doc """
  Human-readable label for a level atom.
  """
  @spec level(atom) :: String.t()
  def level(:graduated), do: "Graduated"
  def level(:level_4), do: "Level 4"
  def level(:level_3), do: "Level 3"
  def level(:level_2), do: "Level 2"
  def level(:level_1d), do: "Level 1D"
  def level(:level_1c), do: "Level 1C"
  def level(:level_1b), do: "Level 1B"
  def level(:level_1a), do: "Level 1A"
  def level(_), do: "—"
end
