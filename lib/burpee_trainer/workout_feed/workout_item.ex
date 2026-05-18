defmodule BurpeeTrainer.WorkoutFeed.WorkoutItem do
  @moduledoc """
  Normalised representation of a plan or video for the Workouts screen.
  The LiveView only works with this struct — it has no knowledge of
  WorkoutPlan or WorkoutVideo directly.
  """

  @type kind :: :plan | :video

  @enforce_keys [:kind, :id, :title, :burpee_type, :duration_sec, :start_path, :inserted_at]

  defstruct [
    :kind,
    :id,
    :title,
    # :six_count | :navy_seal
    :burpee_type,
    # atom from Levels.level_for_count/2, nil for videos without burpee_count
    :level,
    # nil for videos where burpee_count is not set
    :burpee_count,
    :duration_sec,
    # e.g. "/session/42" or "/videos/7"
    :start_path,
    # nil for videos
    :edit_path,
    # DateTime | nil — latest session.inserted_at for plans
    :last_used_at,
    # DateTime — used as sort tiebreaker
    :inserted_at
  ]
end
