defmodule BurpeeTrainer.Mcp.WorkoutFormat do
  @moduledoc """
  The `burpee://workout-format` resource: how a workout is described, in burpee terms.
  Field names and values come from `WorkoutRequest` and `WorkoutLayout`, the reps from
  `Levels`; a test fails if a field or value is left unexplained.
  """

  alias BurpeeTrainer.Levels
  alias BurpeeTrainer.Coach.{WorkoutLayout, WorkoutRequest}

  # The worked example in Timing; a test fits it and checks the numbers the text gives.
  @example_duration_sec 373
  @example_share_sec 60
  @example_phases [
    %{
      "sets" => List.duplicate(%{"reps" => 10, "sec_per_rep" => 10, "sec_per_burpee" => 3}, 3),
      "rests" => [%{"sec" => 20}, %{"share" => 1}]
    }
  ]

  def uri, do: "burpee://workout-format"

  @doc "The worked example as a full authoring form, and the rests it should come to."
  def example do
    {%{
       "name" => "Worked example",
       "rationale" => "Shows how rests are counted.",
       "burpee_type" => "six_count",
       "target_reps" => 30,
       "target_duration_sec" => @example_duration_sec,
       "pacing_style" => "even",
       "recovery" => "optional",
       "timed_rests" => [],
       "phases" => @example_phases
     }, [20.0, @example_share_sec * 1.0]}
  end

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

    `rests`: one per gap between the phase's sets, in order. `{"sec": n}` is exactly n
    seconds; `{"share": w}` takes a share of the time left. See Timing.

    ## Timing

    Every rep starts on a beat `sec_per_rep` long: `sec_per_burpee` of movement, then the
    rest of the beat, its tail (`sec_per_rep - sec_per_burpee`; 0 when unbroken).

    - A set runs from its first rep's start to the end of its last rep's movement:
      `(reps - 1) × sec_per_rep + sec_per_burpee`.
    - Between two sets comes the last rep's tail, then the rest you give. `{"sec": 20}` is
      exactly 20 s after the tail, and `{"sec": 0}` starts the next set on the next beat.
      The tail is never part of the rest and never needs adding to it.
    - `{"share": w}` takes a share, by weight, of the phase's time left once its sets, tails
      and exact rests are counted. Equal shares are equal rests.
    - The workout ends when its last rep's movement ends; the tail after the final rep is not
      counted. 60 reps, one every 20 s with 4 s moving, is 19:44, not 20:00.
    - `timed_rests` split the workout into phases: a phase ends where the next timed rest
      starts, and the last phase ends at `target_duration_sec`. A timed rest's
      `duration_sec` includes the tail of the rep before it, so it must be longer than that
      tail.
    - A phase with at least one gap ends exactly where it should. Shares take up whatever
      time is left. With only exact rests, the sets, tails and rests must add up exactly; if
      they don't, the error says by how much.
    - A phase of one set has nothing to stretch, so it may end up to
      #{WorkoutRequest.timing_tolerance_sec()} s off; the workout's length is then what it
      really comes to.
    - Times are whole milliseconds (at most three decimals); the workout is whole seconds.

    ### Worked example

    Three sets of 10 at 10 s per rep with 3 s moving, an exact 20 s rest, then a share,
    in #{@example_duration_sec} s:

    ```json
    #{Jason.encode!(@example_phases, pretty: true)}
    ```

    - Each set: 9 × 10 + 3 = 93 s, so 279 s of sets.
    - Two gaps, each with a 7 s tail: 14 s.
    - The exact rest: 20 s. That is 313 s counted.
    - The share takes the rest: #{@example_duration_sec} - 313 = #{@example_share_sec} s.

    So the rests are 20 s and #{@example_share_sec} s. Written as `[{"sec": 20},
    {"sec": #{@example_share_sec}}]` the workout is the same; written as `[{"sec": 20},
    {"sec": 52}]` it ends 8 s early, and the error says to add 8 s or use a share.

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
