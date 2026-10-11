defmodule BurpeeTrainer.Coach.VoiceTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Coach.Voice
  alias BurpeeTrainer.Levels

  test "the voice speaks to the athlete and states the level rules the app enforces" do
    text = Voice.text()

    assert text =~ ~s(as "you")
    assert text =~ "no exclamation marks"
    assert text =~ "one 20-minute session"
    assert text =~ "both types reach it in the same week"
    assert text =~ "within #{Levels.window_days(:level_1b)} days"
    assert text =~ "#{Levels.window_days(:graduated)} days for Graduated"
  end
end
