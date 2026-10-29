defmodule BurpeeTrainerWeb.HomeStudioComponents do
  @moduledoc """
  The studio: Edit and New as a chat, in place of Home. The coach speaks first (Edit with
  today's workout as a card, New with one question at a time); you answer by tapping,
  swiping or writing; a proposal arrives as a new card with an Accept pill; back leaves
  without a change. See `docs/specs/2026-10-29-design-chat-design.md`.
  """
  use BurpeeTrainerWeb, :html

  alias BurpeeTrainer.Coach.NewDefaults
  alias BurpeeTrainerWeb.{CreationParameters, HomeWorkoutComponents, HomeWorkoutRequest}

  @new_steps [:type, :style, :duration, :reps, :pace, :ready]

  @doc "Whether Home gives way to the studio."
  def studio?(state), do: state.authoring_stage in [:new, :editing, :review, :saved]

  defp edit?(state), do: not is_nil(state.editing_source)

  defp heading(state), do: if(edit?(state), do: "Edit workout", else: "New workout")

  defp wizard?(state), do: state.authoring_stage == :new and state.new_step != :ready

  defp subtitle(%{editing_source: source} = state) when not is_nil(source),
    do: state.home_selection.plan.name

  defp subtitle(%{authoring_stage: :new, new_step: :ready}), do: "Ready to send"

  defp subtitle(%{authoring_stage: :new, new_step: step}),
    do: "Question #{step_number(step)} of #{length(@new_steps) - 1}"

  defp subtitle(%{workout_parameters: params}), do: HomeWorkoutRequest.summary(params)

  defp step_number(step), do: Enum.find_index(@new_steps, &(&1 == step)) + 1

  attr(:state, :map, required: true)

  def studio(assigns) do
    ~H"""
    <section id="home-studio" class="studio" data-stage={@state.authoring_stage}>
      <.header state={@state} />
      <.question :if={wizard?(@state)} state={@state} />
      <ol
        :if={not wizard?(@state)}
        id="studio-thread"
        class="studio-thread"
        aria-label="Conversation with the coach"
      >
        <.edit_thread :if={edit?(@state)} state={@state} />
        <.new_thread :if={not edit?(@state)} state={@state} />
        <li :if={@state.local_error} id="home-adjustment-error" role="status" class="studio-error">
          {@state.local_error}
        </li>
      </ol>
      <.dock state={@state} />
    </section>
    """
  end

  attr(:state, :map, required: true)

  # Back: out of Edit; for New one question back (out of the first). New also has a close.
  defp header(assigns) do
    state = assigns.state
    first? = state.authoring_stage == :new and state.new_step == :type
    leaves? = edit?(state) or first?

    assigns =
      assign(assigns,
        leaves?: leaves?,
        back_id: if(leaves?, do: "home-request-abort", else: "studio-back"),
        back_label:
          cond do
            edit?(state) -> "Cancel edit"
            first? -> "Cancel new workout"
            true -> "Previous question"
          end
      )

    ~H"""
    <header class="studio-header">
      <button
        id={@back_id}
        type="button"
        class="studio-back"
        aria-label={@back_label}
        title="Back"
        phx-click={
          if(@leaves?,
            do: JS.push("abort_new_workout") |> JS.focus(to: "#home-summary"),
            else: JS.push("back_new_step")
          )
        }
      >
        <.icon name="hero-chevron-left" class="size-5" />
      </button>
      <div class="studio-heading">
        <h1 id="home-authoring-heading" class="studio-title">{heading(@state)}</h1>
        <p class="studio-subtitle">{subtitle(@state)}</p>
      </div>
      <button
        :if={not @leaves?}
        id="home-request-abort"
        type="button"
        class="studio-close"
        aria-label="Cancel new workout"
        title="Close"
        phx-click={JS.push("abort_new_workout") |> JS.focus(to: "#home-summary")}
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </header>
    """
  end

  ## Edit

  attr(:state, :map, required: true)

  defp edit_thread(assigns) do
    state = assigns.state
    proposed? = state.authoring_stage == :review and not is_nil(state.pending_request)
    asked? = proposed? or state.busy?

    assigns = assign(assigns, proposed?: proposed?, asked?: asked?)

    ~H"""
    <li class="studio-msg studio-coach">
      <.card
        id="studio-source"
        label="Today’s workout"
        name={@state.home_selection.plan.name}
        seconds={@state.home_selection.plan.target_duration_sec}
        reps={@state.home_selection.plan.target_reps}
        rows={@state.inspection_rows}
        expanded={@state.expanded_groups}
        table?={not @asked?}
      />
    </li>
    <li :if={not @asked?} class="studio-msg studio-coach">
      <p class="studio-text">What would you like to change?</p>
    </li>
    <.proposal_thread :if={@asked?} state={@state} />
    """
  end

  attr(:state, :map, required: true)

  # The asks so far and what each became, then the proposal now on screen, then the ask
  # in flight, each below the last.
  defp proposal_thread(assigns) do
    state = assigns.state
    first_busy? = state.busy? and is_nil(state.pending_turn) and state.authoring_stage != :review
    assigns = assign(assigns, first_busy?: first_busy?, refining?: is_binary(state.pending_turn))

    ~H"""
    <%= for turn <- @state.design_turns do %>
      <li class="studio-msg studio-you">
        <p class="studio-bubble">{turn.instruction}</p>
      </li>
      <li class="studio-msg studio-coach">
        <p class="studio-turn">
          {turn.name} · {minutes(turn.duration_sec)} min · {turn.reps} reps
        </p>
      </li>
    <% end %>
    <li :if={ask(@state) != ""} class="studio-msg studio-you">
      <p id="home-design-ask" class="studio-bubble">{ask(@state)}</p>
    </li>
    <li :if={@first_busy?} class="studio-msg studio-coach">
      <.working />
    </li>
    <li
      :if={@state.authoring_stage == :review and @state.pending_request}
      class="studio-msg studio-coach"
    >
      <.proposal state={@state} stale?={@state.busy?} />
    </li>
    <li :if={@refining?} class="studio-msg studio-you">
      <p id="home-design-pending" class="studio-bubble">{@state.pending_turn}</p>
    </li>
    <li :if={@refining?} class="studio-msg studio-coach"><.working /></li>
    <li
      :if={@state.authoring_stage == :review and @state.busy? and not @refining?}
      class="studio-msg studio-coach"
    >
      <.working label="Saving…" />
    </li>
    """
  end

  # What was asked for the proposal on screen: your words in Edit and in a follow-up; New's
  # first ask is the message its questions made.
  defp ask(state) do
    if edit?(state) or state.design_turns != [],
      do: state.instruction,
      else:
        HomeWorkoutRequest.message(state.workout_parameters, state.workout_parameters.note || "")
  end

  attr(:state, :map, required: true)
  attr(:stale?, :boolean, default: false)

  defp proposal(assigns) do
    definition = assigns.state.pending_request.definition
    assigns = assign(assigns, definition: definition)

    ~H"""
    <div id="home-edit-review" class={["studio-proposal", @stale? && "studio-proposal-stale"]}>
      <.card
        id="studio-proposal"
        label="Proposal"
        name={@definition["name"]}
        seconds={@definition["target_duration_sec"]}
        reps={@definition["target_reps"]}
        note={@definition["rationale"]}
        rows={@state.review_inspection_rows}
        compare={if edit?(@state), do: @state.inspection_rows}
        expanded={@state.expanded_groups}
      />
      <p
        :if={@state.pending_request.request.timed_rests != []}
        id="home-edit-review-pauses"
        class="studio-turn"
      >
        {pauses_label(@state.pending_request.request.timed_rests)}
      </p>
    </div>
    """
  end

  attr(:label, :string, default: "Working on it…")

  defp working(assigns) do
    ~H"""
    <div id="home-update-loading" role="status" class="studio-working" aria-label={@label}>
      <.burpee_loader class="studio-spinner" size={44} />
      <span id="home-edit-progress" class="studio-turn">{@label}</span>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:name, :string, required: true)
  attr(:seconds, :any, required: true)
  attr(:reps, :any, required: true)
  attr(:note, :string, default: nil)
  attr(:rows, :list, default: [])
  attr(:compare, :any, default: nil)
  attr(:expanded, :any, default: MapSet.new())
  attr(:table?, :boolean, default: true)

  # A workout, as the coach shows it: a label, its name, its totals as two chips, a line on
  # why, and the table when it is the one being discussed.
  defp card(assigns) do
    ~H"""
    <article id={@id} class="studio-card">
      <p class="studio-card-label">{@label}</p>
      <h2 class="studio-card-name">{@name}</h2>
      <p class="studio-card-totals">
        <span class="studio-chip">{minutes(@seconds)} min</span>
        <span class="studio-chip">{@reps} reps</span>
      </p>
      <p :if={@note && @table?} class="studio-card-note">{@note}</p>
      <div :if={@table?} class="studio-card-table">
        <HomeWorkoutComponents.inspection rows={@rows} compare={@compare} expanded={@expanded} />
      </div>
    </article>
    """
  end

  ## New

  attr(:state, :map, required: true)

  # Once the questions are answered the chat opens on a message made of them (in the box
  # below), with what was chosen above as parts you can change.
  defp new_thread(%{state: %{authoring_stage: :new}} = assigns) do
    ~H"""
    <li :if={not @state.busy?} class="studio-msg studio-coach">
      <p class="studio-text">Here is what you chose. Send it as it is, or add a request.</p>
      <.parts state={@state} />
    </li>
    <.proposal_thread :if={@state.busy?} state={@state} />
    """
  end

  defp new_thread(%{state: %{authoring_stage: :saved}} = assigns) do
    ~H"""
    <li id="home-new-saved" class="studio-msg studio-coach">
      <p class="studio-text">
        Saved {@state.created_plan.name}. Your current workout is unchanged.
      </p>
      <div class="studio-pills">
        <button id="home-new-dismiss" type="button" class="studio-pill" phx-click="abort_new_workout">
          Keep current
        </button>
        <button
          id="home-new-select"
          type="button"
          class="studio-pill studio-pill-primary"
          phx-click="select_created_workout"
        >
          <.icon name="hero-check" class="size-4" /> Use this one
        </button>
      </div>
    </li>
    """
  end

  defp new_thread(assigns) do
    ~H"""
    <.proposal_thread state={@state} />
    """
  end

  attr(:state, :map, required: true)

  defp parts(assigns) do
    params = assigns.state.workout_parameters

    assigns =
      assign(assigns,
        parts: [
          {:type, CreationParameters.type_label(params.burpee_type)},
          {:style, style_label(params.pacing_style)},
          {:duration, "#{duration_minutes(params)} min"},
          {:reps, "#{params.reps} reps"},
          {:pace, pace_label(params.pace)}
        ]
      )

    ~H"""
    <p id="studio-request" class="studio-parts">
      <button
        :for={{step, text} <- @parts}
        id={"studio-part-#{step}"}
        type="button"
        class="studio-part"
        phx-click="goto_new_step"
        phx-value-step={step}
        aria-label={"Change #{text}"}
      >
        {text}
      </button>
    </p>
    """
  end

  attr(:state, :map, required: true)

  # One question at a time. A tap on a choice answers and moves on; a value you swipe has a
  # Next, since nothing says you are done.
  defp question(assigns) do
    step = assigns.state.new_step

    assigns =
      assign(assigns, step: step, number: step_number(step), total: length(@new_steps) - 1)

    ~H"""
    <section id="studio-step" class="studio-step" data-step={@step} aria-labelledby="studio-question">
      <ol class="studio-dots" aria-label={"Question #{@number} of #{@total}"}>
        <li :for={n <- 1..@total} class={["studio-dot", n <= @number && "studio-dot-on"]}></li>
      </ol>
      <h2 id="studio-question" class="studio-question">{question_text(@step)}</h2>
      <.controls step={@step} state={@state} />
      <p :if={@state.local_error} id="home-adjustment-error" role="status" class="studio-error">
        {@state.local_error}
      </p>
    </section>
    """
  end

  defp question_text(:type), do: "Which burpee?"
  defp question_text(:style), do: "How should the sets go?"
  defp question_text(:duration), do: "How long?"
  defp question_text(:reps), do: "How many reps?"
  defp question_text(:pace), do: "How fast is each rep?"

  attr(:step, :atom, required: true)
  attr(:state, :map, required: true)

  defp controls(%{step: :type} = assigns) do
    ~H"""
    <div class="studio-options" role="group" aria-label="Burpee type">
      <.option
        :for={
          {text, value, detail} <- [
            {"Six-count", "six_count", "The classic: down, back, push-up, up. About 4 to 5 s a rep."},
            {"Navy SEAL", "navy_seal", "Slower and heavier. About 7 to 9 s a rep."}
          ]
        }
        field="burpee_type"
        text={text}
        value={value}
        detail={detail}
      />
    </div>
    """
  end

  defp controls(%{step: :style} = assigns) do
    ~H"""
    <div class="studio-options" role="group" aria-label="Set style">
      <.option
        :for={
          {text, value, detail} <- [
            {"Even", "even", "A steady beat, with a pause between reps."},
            {"Unbroken", "unbroken", "Reps back to back, with rest between sets."}
          ]
        }
        field="pacing_style"
        text={text}
        value={value}
        detail={detail}
      />
    </div>
    """
  end

  defp controls(%{step: :duration} = assigns) do
    remaining = assigns.state.slot && assigns.state.slot.remaining_sec
    options = NewDefaults.durations(remaining)
    minutes = duration_minutes(assigns.state.workout_parameters)

    assigns =
      assign(assigns,
        stepper: %{
          field: "duration",
          value: minutes,
          unit: "min",
          label: "Duration in minutes",
          at_min?: minutes <= hd(options),
          at_max?: minutes >= List.last(options),
          hint:
            if(remaining,
              do: "#{div(remaining, 60)} min left this week",
              else: "Swipe to change"
            )
        }
      )

    ~H"""
    <.stepper {@stepper} />
    """
  end

  defp controls(%{step: :reps} = assigns) do
    params = assigns.state.workout_parameters
    seconds = duration_seconds(params)
    pace = params.pace || NewDefaults.default_pace(type(params), params.reps, seconds)

    assigns =
      assign(assigns,
        stepper: %{
          field: "reps",
          value: params.reps,
          unit: "reps",
          label: "Reps",
          at_min?: params.reps <= 5,
          at_max?: params.reps + 5 > NewDefaults.max_reps(pace, seconds),
          hint: "Suggested from your recent sessions"
        }
      )

    ~H"""
    <.stepper {@stepper} />
    """
  end

  defp controls(%{step: :pace} = assigns) do
    params = assigns.state.workout_parameters
    seconds = duration_seconds(params)

    assigns =
      assign(assigns,
        stepper: %{
          field: "pace",
          value: format_pace(params.pace),
          unit: "s per rep",
          label: "Seconds of movement per rep",
          at_min?: params.pace <= 0.5,
          at_max?: params.reps * (params.pace + 0.5) > seconds,
          hint: "The rest of the time is recovery"
        }
      )

    ~H"""
    <.stepper {@stepper} />
    """
  end

  attr(:field, :string, required: true)
  attr(:text, :string, required: true)
  attr(:value, :string, required: true)
  attr(:detail, :string, required: true)

  # A choice is a card to tap, which answers the question.
  defp option(assigns) do
    ~H"""
    <button
      id={"home-pill-#{@field}-#{@value}"}
      type="button"
      class="studio-option"
      phx-click="choose_workout_value"
      phx-value-field={@field}
      value={@value}
    >
      <span class="studio-option-title">{@text}</span>
      <span class="studio-option-detail">{@detail}</span>
    </button>
    """
  end

  attr(:field, :string, required: true)
  attr(:value, :any, required: true)
  attr(:unit, :string, required: true)
  attr(:label, :string, required: true)
  attr(:at_min?, :boolean, required: true)
  attr(:at_max?, :boolean, required: true)
  attr(:hint, :string, required: true)

  # A value to swipe: right for more, left for less. The buttons and arrow keys do the same.
  defp stepper(assigns) do
    ~H"""
    <div class="studio-stepper-wrap">
      <div
        id={"studio-step-#{@field}"}
        class="studio-stepper"
        phx-hook="SwipeValue"
        data-field={@field}
        role="spinbutton"
        tabindex="0"
        aria-label={@label}
        aria-valuenow={@value}
        aria-valuetext={"#{@value} #{@unit}"}
      >
        <button
          id={"studio-#{@field}-down"}
          type="button"
          class="studio-step-button"
          phx-click="step_workout_value"
          phx-value-field={@field}
          phx-value-dir="down"
          aria-label={"Less #{@field}"}
          disabled={@at_min?}
        >
          <.icon name="hero-minus" class="size-6" />
        </button>
        <div class="studio-step-value" aria-hidden="true">
          <span id={"studio-#{@field}-value"} class="studio-step-number">{@value}</span>
          <span class="studio-step-unit">{@unit}</span>
        </div>
        <button
          id={"studio-#{@field}-up"}
          type="button"
          class="studio-step-button"
          phx-click="step_workout_value"
          phx-value-field={@field}
          phx-value-dir="up"
          aria-label={"More #{@field}"}
          disabled={@at_max?}
        >
          <.icon name="hero-plus" class="size-6" />
        </button>
      </div>
      <p class="studio-step-hint">{@hint}</p>
    </div>
    <div class="studio-step-actions">
      <button
        id="studio-next"
        type="button"
        class="studio-pill studio-pill-primary studio-pill-wide"
        phx-click="next_new_step"
      >
        Next
      </button>
    </div>
    """
  end

  ## Dock

  attr(:state, :map, required: true)

  # What you can do now: Accept or Save a proposal, tap a quick change, write. It is docked
  # above the keyboard (see the ChatDock hook), so it stays within reach as the thread grows.
  defp dock(assigns) do
    state = assigns.state
    proposed? = state.authoring_stage == :review
    questions? = state.authoring_stage == :new and state.new_step != :ready
    visible? = not questions? and state.authoring_stage != :saved

    assigns =
      assign(assigns,
        proposed?: proposed?,
        visible?: visible?,
        event: event(state),
        send_always?: not edit?(state) and not proposed?,
        placeholder: placeholder(state)
      )

    ~H"""
    <div
      :if={@visible?}
      id="home-chat-dock"
      class="chat-dock"
      phx-hook="ChatDock"
      data-version={version(@state)}
      data-scroll-to={scroll_target(@state)}
    >
      <div class="chat-dock-inner">
        <div :if={@proposed?} id="home-chat-actions" class="studio-pills studio-pills-dock">
          <button
            id="home-request-save"
            type="button"
            class="studio-pill"
            phx-click="save_review_to_library"
            disabled={@state.busy?}
          >
            <.icon name="hero-bookmark" class="size-4" /> Save
          </button>
          <button
            id="home-request-confirm"
            type="button"
            class="studio-pill studio-pill-primary"
            phx-click="confirm_workout_request"
            disabled={@state.busy?}
          >
            <.icon name="hero-check" class="size-4" /> Accept
          </button>
        </div>
        <div
          :if={edit?(@state) and not @state.busy?}
          class="composer-suggestions chat-dock-chips"
          role="group"
          aria-label="Suggested changes"
        >
          <button
            :for={{id, label, instruction} <- suggestions()}
            id={"home-edit-suggest-#{id}"}
            type="button"
            class="composer-suggestion"
            phx-click={
              JS.push(@event, value: %{"home_adjustment" => %{"instruction" => instruction}})
            }
          >
            {label}
          </button>
        </div>
        <.form
          for={@state.adjustment_form}
          id="home-edit-form"
          class="home-authoring-form"
          phx-submit={@event}
          phx-change="change_current_edit"
          aria-busy={to_string(@state.busy?)}
        >
          <div class="composer">
            <.input
              field={@state.adjustment_form[:instruction]}
              id="home-edit-instruction"
              type="textarea"
              label={if(edit?(@state), do: "What do you want to change?", else: "Anything else?")}
              placeholder={@placeholder}
              rows="1"
              maxlength={if(edit?(@state), do: "500", else: "400")}
              class="composer-input"
              disabled={@state.busy?}
              phx-hook="ComposerCaret"
              data-caret={if(@state.authoring_stage == :new, do: "end")}
            />
            <div class="composer-bar">
              <span></span>
              <button
                id="home-edit-send"
                type="submit"
                class={["composer-send", @send_always? && "composer-send-ready"]}
                aria-label="Send"
                title="Send"
                disabled={@state.busy?}
              >
                <span><.icon name="hero-arrow-up" class="size-5" /></span>
              </button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    <div :if={@visible?} id="home-chat-end" class="chat-dock-spacer" aria-hidden="true"></div>
    """
  end

  # The first message of an edit starts the design; New's send makes its first proposal; every
  # later one refines the proposal.
  defp event(%{authoring_stage: :review}), do: "refine_workout"
  defp event(%{editing_source: nil}), do: "send_new_workout"
  defp event(_state), do: "review_current_edit"

  defp placeholder(%{authoring_stage: :review}), do: "Change anything else?"
  defp placeholder(%{editing_source: nil}), do: "Anything else? Or just send"
  defp placeholder(_state), do: "What should change?"

  defp suggestions do
    [
      {"split", "Split into sets", "Split it into sets with a short rest between them"},
      {"rests", "Longer rests", "Make the rests longer"},
      {"shorter", "Make it shorter", "Make it shorter"}
    ]
  end

  # The newest thing said: your pending message while the coach works, else your last one.
  defp scroll_target(%{pending_turn: turn}) when is_binary(turn), do: "#home-design-pending"
  defp scroll_target(_state), do: "#home-design-ask"

  defp version(state),
    do:
      "#{state.authoring_stage}:#{length(state.design_turns)}:#{is_binary(state.pending_turn)}:#{state.busy?}"

  ## Labels

  defp minutes(seconds), do: div(round(seconds), 60)

  defp duration_seconds(params) do
    {:ok, seconds} = CreationParameters.duration_seconds(params.duration)
    seconds
  end

  defp duration_minutes(params), do: div(duration_seconds(params), 60)
  defp type(params), do: String.to_existing_atom(params.burpee_type)

  defp style_label("even"), do: "Even"
  defp style_label("unbroken"), do: "Unbroken"

  defp pace_label(nil), do: "Coach picks the pace"
  defp pace_label(pace), do: "#{format_pace(pace)} s per rep"

  defp format_pace(nil), do: "–"
  defp format_pace(pace), do: :erlang.float_to_binary(pace * 1.0, decimals: 1)

  defp pauses_label([_one] = rests), do: "Pause: " <> pause_times(rests)
  defp pauses_label(rests), do: "Pauses: " <> pause_times(rests)

  defp pause_times(rests),
    do:
      Enum.map_join(rests, " · ", fn rest ->
        "#{rest.duration_sec}s at #{CreationParameters.duration_label(round(rest.start_sec))}"
      end)
end
