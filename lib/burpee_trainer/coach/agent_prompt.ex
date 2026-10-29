defmodule BurpeeTrainer.Coach.AgentPrompt do
  @moduledoc "Bounded scoped facts shared by conversation, planning, and authoring."
  alias BurpeeTrainer.Coach.{Memory, Tools, Policy, Voice}
  alias BurpeeTrainer.{Levels, Workouts}

  # How the next session moves on from the last one of its type, designed or picked.
  @progression "The progression decision in context is authoritative: follow its action and " <>
                 "min_reps_per_20/max_reps_per_20 range as well as the rep ceiling. " <>
                 "It derives repeat, progress or ease from comparable completed sessions, " <>
                 "feedback and fatigue. Missing feedback is not evidence of an easy session. " <>
                 "Arrange sets and explain the evidence; do not invent a different progression " <>
                 "decision. Keep the full slot duration. Shorter rests at unchanged reps and " <>
                 "duration are not greater density. A missed maintenance week alone is not " <>
                 "evidence of lost capacity. When their feedback names a recent limiter " <>
                 "(legs, upper body, breathing or the whole body), arrange the sets to spare " <>
                 "it with shorter sets and fuller recovery inside the same reps and duration."

  @planner_task """
  Plan the athlete's next session. Prefer a saved or built-in workout that fits, with \
  select_workout; otherwise design one with propose_workout. Base it on their recent \
  sessions of this burpee type: stay near the reps they have been doing, and go easier only \
  when their feedback, fatigue or memory gives a reason. A level that lapsed from missed weeks is no \
  reason; they still have the fitness. Never go more than 10% above their best 20-minute reps \
  for this type in the last eight weeks, whatever their level; only with no session of the \
  type in that time does the level after their current one cap it. For a session longer \
  than 20 minutes, compare its reps per 20 minutes with the landmarks and their recent \
  sessions. #{@progression} The rationale appears under the workout: one sentence in the voice above on why this session \
  suits them now; why, not what, since the name, reps and minutes are shown above it. Finish with one sentence explaining your choice.
  """

  @planner_create_task """
  Design the athlete's next session with propose_workout: none of their saved or built-in \
  workouts suits them today. Never go more than 10% above their best 20-minute reps for \
  this type in the last eight weeks (with no recent session, above the level after their \
  current one); easier sessions are fine. For a session longer than 20 minutes, compare its \
  reps per 20 minutes with the landmarks. #{@progression} The rationale appears under the workout: one sentence in the voice \
  above on why this session suits them now; why, not what, since the name, reps and minutes \
  are shown above it. Finish with one sentence explaining your design.
  """

  @coach_page_task """
  Answer the way a coach would across the gym floor, in at most three sentences, starting \
  from what the athlete just said. When they tell you how a session felt, that something \
  hurt, or that their week has changed, take it in and say what it means for their next \
  sessions; what they tell you about themselves is noted for you after the conversation, so \
  you may say you will keep it in mind. Bring in their notes and recent sessions only when \
  they bear on what was said, as someone who remembers them would; leave trends, totals and \
  levels out unless they ask. Ask at most one short question, and only when the answer would \
  change their training. Use propose_goal only when they ask for a goal; they confirm it \
  themselves. In suggestions, give up to three short things the athlete is likely to say \
  next, in their own words and specific to this reply (under 60 characters each); they tap \
  one to send it.
  """

  @context_glossary """
  The context that follows is JSON. memory: short notes on what you know about the athlete \
  from earlier, oldest first. goals: \
  their active and proposed goals. current_level: the level they hold now. landmarks: the \
  reps each level needs in 20 minutes, per burpee type. recent_sessions: their latest \
  sessions first, with reps and reps_planned, duration_sec and duration_sec_planned, pace_sec \
  (seconds per rep) and their feedback (mood: -1 rough, 0 OK, 1 good). \
  fatigue is null without the camera; camera_coverage is the share of planned reps it caught, \
  and when it missed the start that is all there is. kept_up: they stayed on or ahead of the \
  beat to the end (finishing a set early is keeping up); slip_at_sec: when they fell behind \
  for good; decline: how much slower than planned the last third was than the first (0.08 \
  is 8%); pace_delta_sec: median seconds slower than planned between reps (negative is \
  ahead); recovery_delta_sec: median seconds later the first rep after a rest lands on its \
  beat than the workout's first rep did (positive is slower to restart). pace_consistency: how \
  even the reps inside each set were against its planned pace, 1 perfectly even. \
  slot: their next session, with its burpee_type and duration_sec; strategy catch_up means \
  today's share of missed minutes across the remaining weekend days; completed_sec, remaining_sec and \
  weekly_target_sec describe this week's training time. progression: the deterministic rate \
  decision, its reason and evidence_ids; limits are reps per 20 minutes, not total reps \
  in a longer session. A null maximum means establish a baseline within the rep ceiling.
  """

  @doc "Progression guidance shared by saved-workout selection and workout design."
  def progression_guidance, do: @progression

  @doc "What the planner is asked to do; also the planning rules Claude coaches by."
  def planner_task, do: @planner_task

  @doc "How to read the context JSON."
  def context_glossary, do: @context_glossary

  def context(scope, slot \\ nil) do
    {:ok, goals} = Tools.Goals.call(scope, %{}, %{})
    sessions = Workouts.list_recent_training_sessions(scope)

    %{
      memory: scope |> Memory.list() |> Enum.map(& &1.text),
      goals: goals["goals"] |> Enum.take(20),
      current_level: Levels.current_level(Workouts.list_sessions(scope)),
      slot: slot,
      progression:
        slot && Map.from_struct(BurpeeTrainer.Coach.Progression.for_type(scope, slot.burpee_type)),
      recent_sessions: sessions |> Enum.take(10) |> Enum.map(&Tools.History.summary/1),
      landmarks:
        Enum.map(Levels.all_levels(), fn level ->
          %{
            level: level,
            six_count: Levels.threshold(level, :six_count),
            navy_seal: Levels.threshold(level, :navy_seal)
          }
        end)
    }
  end

  # `history` is the conversation so far, as `{message, reply}` pairs, oldest first; the
  # coach's turns read as it wrote them.
  def messages(scope, surface, input, slot, history \\ []) do
    slot =
      slot ||
        case Policy.required_slot(scope, DateTime.utc_now(:second)) do
          {:ok, s} -> s
          _ -> nil
        end

    rule =
      case surface do
        :planner ->
          Voice.text() <> "\n" <> @planner_task <> "\n" <> @context_glossary

        :planner_create ->
          Voice.text() <> "\n" <> @planner_create_task <> "\n" <> @context_glossary

        :coach_page ->
          Voice.text() <> "\n" <> @coach_page_task <> "\n" <> @context_glossary
      end

    messages = [
      %{role: "system", content: rule},
      %{
        role: "system",
        content: Jason.encode!(context(scope, slot))
      }
    ]

    if surface == :coach_page do
      turns =
        Enum.flat_map(history, fn {message, reply} ->
          [
            %{role: "user", content: message},
            %{role: "assistant", content: Jason.encode!(%{"reply" => reply})}
          ]
        end)

      messages ++ turns ++ [%{role: "user", content: input}]
    else
      messages
    end
  end
end
