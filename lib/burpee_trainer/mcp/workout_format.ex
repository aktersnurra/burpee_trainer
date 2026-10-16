defmodule BurpeeTrainer.Mcp.WorkoutFormat do
  @moduledoc """
  The `burpee://workout-format` resource: how a workout is described, in burpee terms.
  Field names and values come from `WorkoutRequest` and `WorkoutLayout`, the reps from
  `Levels`; a test fails if a field or value is left unexplained.
  """

  alias BurpeeTrainer.Levels
  alias BurpeeTrainer.Coach.{WorkoutLayout, WorkoutRequest}

  def uri, do: "burpee://workout-format"

  def text do
    """
    # How a workout is described

    A workout has two parts: what it asks for, and how its reps are laid out.

    ## What it asks for

    - `burpee_type`: `six_count` (six-count burpee) or `navy_seal` (Navy SEAL burpee: three
      push-ups per rep instead of one; much slower).
    - `target_reps`: total reps in the workout.
    - `target_duration_sec`: how long the workout lasts, in seconds.
    - `pacing_style`:
      - `even`: every rep starts on a fixed beat, with a short rest after each rep
        (seconds per rep is longer than the movement).
      - `unbroken`: reps back to back within each set, no rest between reps (seconds
        per rep equals the movement).
    - `recovery`: rests between sets.
      - `required`: every set is followed by a rest.
      - `forbidden`: no rests at all.
      - `optional`: rests where the layout puts them.
    - `timed_rests`: fixed rests at a point in the workout, each `start_sec` (seconds from
      the start) and `duration_sec`. They split the workout into phases: one more phase
      than timed rests.
    - `requested_pace_sec`: movement seconds per rep the athlete asked for, or null.
    - `set_reps`: reps of each set when the athlete states them; empty otherwise.

    ## The layout

    Phases in order; each phase has sets, and each set has:

    - `reps`: reps in the set.
    - `sec_per_rep`: seconds from the start of one rep to the start of the next.
    - `sec_per_burpee`: seconds of movement in one rep, at most `sec_per_rep`. The
      difference is the rest after each rep.

    `rest_weights` share a phase's remaining time between its sets: one weight per gap,
    equal weights mean equal rests.

    JSON schema of what it asks for:

    ```json
    #{Jason.encode!(WorkoutRequest.json_schema(), pretty: true)}
    ```

    JSON schema of the layout (for a workout with no timed rests):

    ```json
    #{Jason.encode!(layout_schema(), pretty: true)}
    ```

    ## Levels

    A level is a number of reps in one 20-minute session, separately per burpee type:

    | Level | Six-count | Navy SEAL |
    |---|---|---|
    #{landmark_rows()}
    """
  end

  defp layout_schema do
    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 1,
        "target_duration_sec" => 1200,
        "pacing_style" => "even",
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => nil
      })

    WorkoutLayout.json_schema(request)
  end

  defp landmark_rows do
    Levels.all_levels()
    |> Enum.map_join("\n", fn level ->
      "| #{label(level)} | #{Levels.threshold(level, :six_count)} | #{Levels.threshold(level, :navy_seal)} |"
    end)
  end

  defp label(:graduated), do: "Graduated"

  defp label(level),
    do:
      "Level " <>
        (level |> Atom.to_string() |> String.replace_prefix("level_", "") |> String.upcase())
end
