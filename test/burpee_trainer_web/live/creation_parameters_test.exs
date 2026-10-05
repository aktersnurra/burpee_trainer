defmodule BurpeeTrainerWeb.CreationParametersTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.CreationParameters

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
