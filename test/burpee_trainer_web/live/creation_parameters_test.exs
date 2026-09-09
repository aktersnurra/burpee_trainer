defmodule BurpeeTrainerWeb.CreationParametersTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.CreationParameters

  test "all choices and note reach the existing bounded request" do
    {:ok, parameters} =
      %CreationParameters{}
      |> CreationParameters.changeset(%{
        burpee_type: "navy_seal",
        duration: "40:00",
        reps: 180,
        pacing: "even",
        distribution: "balanced",
        note: "More recovery"
      })
      |> Ecto.Changeset.apply_action(:validate)

    assert CreationParameters.request(parameters) ==
             "Navy SEAL; duration: 2400 seconds; total reps: 180; pacing: Even; distribution: Balanced.\nNote: More recovery"

    maximum = %{parameters | note: String.duplicate("😀", 300), duration: "1440:00", reps: 100_000}
    assert String.length(CreationParameters.request(maximum)) <= 500
    assert byte_size(CreationParameters.request(maximum)) <= 4_000
  end

  test "rejects invalid and unknown control values" do
    for attrs <- [
          %{reps: 0},
          %{duration: "20:99"},
          %{duration: "1440:01"},
          %{duration: "0:00"},
          %{pacing: "invented"},
          %{burpee_type: "other"},
          %{distribution: "other"},
          %{note: String.duplicate("a", 301)}
        ] do
      refute CreationParameters.changeset(%CreationParameters{}, attrs).valid?
    end
  end
end
