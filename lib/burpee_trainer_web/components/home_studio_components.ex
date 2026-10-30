defmodule BurpeeTrainerWeb.HomeStudioComponents do
  @moduledoc """
  The studio: Edit and New as a chat, in place of Home. The coach speaks first (Edit with
  today's workout as a card, New with one question at a time); you answer by tapping,
  swiping or writing; a proposal arrives as a new card with an Accept pill; back leaves
  without a change. See `docs/specs/2026-10-29-design-chat-design.md`.
  """
  use BurpeeTrainerWeb, :html

  alias BurpeeTrainer.Coach.NewDefaults

  alias BurpeeTrainerWeb.{CreationParameters, HomeWorkoutComponents, NewWorkoutSteps}

  @doc "Whether Home gives way to the studio."
  def studio?(state), do: state.authoring_stage in [:new, :editing, :review, :saved]

  defp edit?(state), do: not is_nil(state.editing_source)

  defp heading(state), do: if(edit?(state), do: "Edit workout", else: "New workout")

  # One screen at a time until the chat: while a request is being sent it is the thread.
  defp wizard?(state),
    do: state.authoring_stage == :new and state.new_step != :request and not state.busy?

  defp step_number(step, params),
    do: Enum.find_index(NewWorkoutSteps.questions(params), &(&1 == step)) + 1

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
      </div>
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
  # first ask is only what was written with its answers, which the screen before showed.
  defp ask(state) do
    if edit?(state) or state.design_turns != [],
      do: state.instruction,
      else: state.workout_parameters.note || ""
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
      <%!-- What to do with it sits right under the card it is about. Run starts it with the
           camera and warmup choices this device remembers from Home. --%>
      <div id="home-chat-actions" class="studio-actions">
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
          id="home-request-run"
          type="button"
          class="studio-pill studio-pill-primary"
          phx-click="run_workout_request"
          disabled={@state.busy?}
        >
          <.icon name="hero-play-solid" class="size-4" /> Run
        </button>
      </div>
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
  attr(:name, :string, required: true)
  attr(:seconds, :any, required: true)
  attr(:reps, :any, required: true)
  attr(:note, :string, default: nil)
  attr(:rows, :list, default: [])
  attr(:compare, :any, default: nil)
  attr(:expanded, :any, default: MapSet.new())
  attr(:table?, :boolean, default: true)

  # A workout, as the coach shows it: its name, its totals as two chips, a line on
  # why, and the table when it is the one being discussed.
  defp card(assigns) do
    ~H"""
    <article id={@id} class="studio-card">
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

  # The chat, opened from what was chosen: the message is in the box, ready to add to.
  defp new_thread(%{state: %{authoring_stage: :new}} = assigns) do
    ~H"""
    <li :if={not @state.busy?} class="studio-msg studio-coach">
      <p class="studio-text">Anything else I should know?</p>
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

  # One question at a time. A tap on a choice answers and moves on; a value you swipe has a
  # Next, since nothing says you are done. The last screen is what was chosen.
  defp question(%{state: %{new_step: :ready}} = assigns) do
    params = assigns.state.workout_parameters

    assigns =
      assign(assigns,
        rows:
          [
            {:type, "Burpee", CreationParameters.type_label(params.burpee_type)},
            {:style, "Style", style_label(params.pacing_style)},
            {:duration, "Duration", "#{duration_minutes(params)} min"},
            {:reps, "Reps", "#{params.reps}"},
            params.pacing_style == "unbroken" &&
              {:sets, "Set size", set_size_label(params.max_set_reps)},
            {:pace, "Pace", pace_label(params.pace)}
          ]
          |> Enum.filter(& &1)
      )

    ~H"""
    <section id="studio-step" class="studio-step" data-step="ready" aria-labelledby="studio-question">
      <h2 id="studio-question" class="studio-question">Ready?</h2>
      <ul id="studio-request" class="studio-summary">
        <li :for={{step, label, value} <- @rows}>
          <button
            id={"studio-row-#{step}"}
            type="button"
            class="studio-summary-row"
            phx-click="goto_new_step"
            phx-value-step={step}
            aria-label={"Change #{String.downcase(label)}: #{value}"}
          >
            <span class="studio-summary-label">{label}</span>
            <span class="studio-summary-value">{value}</span>
            <.icon name="hero-chevron-right" class="size-4 studio-summary-chevron" />
          </button>
        </li>
      </ul>
      <p :if={@state.local_error} id="home-adjustment-error" role="status" class="studio-error">
        {@state.local_error}
      </p>
      <div class="studio-step-actions studio-ready-actions">
        <button
          id="studio-create"
          type="button"
          class="studio-pill studio-pill-primary studio-pill-wide"
          phx-click="send_new_workout"
        >
          Create workout
        </button>
        <button
          id="studio-add-request"
          type="button"
          class="studio-pill studio-pill-wide"
          phx-click="add_new_request"
        >
          Add a request
        </button>
      </div>
    </section>
    """
  end

  defp question(assigns) do
    step = assigns.state.new_step
    params = assigns.state.workout_parameters

    assigns =
      assign(assigns,
        step: step,
        number: step_number(step, params),
        total: length(NewWorkoutSteps.questions(params))
      )

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
  defp question_text(:sets), do: "Most reps in one set?"
  defp question_text(:pace), do: "How fast is each rep?"

  attr(:step, :atom, required: true)
  attr(:state, :map, required: true)

  defp controls(%{step: :type} = assigns) do
    ~H"""
    <div class="studio-options" role="group" aria-label="Burpee type">
      <.option
        :for={{text, value} <- [{"Six-count", "six_count"}, {"Navy SEAL", "navy_seal"}]}
        field="burpee_type"
        text={text}
        value={value}
      />
    </div>
    """
  end

  defp controls(%{step: :style} = assigns) do
    ~H"""
    <div class="studio-options" role="group" aria-label="Set style">
      <.option
        :for={{text, value} <- [{"Even", "even"}, {"Unbroken", "unbroken"}]}
        field="pacing_style"
        text={text}
        value={value}
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
          hint: split(params, params.pace || pace)
        }
      )

    ~H"""
    <.stepper {@stepper} />
    """
  end

  defp controls(%{step: :sets} = assigns) do
    params = assigns.state.workout_parameters
    options = NewDefaults.set_sizes(params.reps)
    current = params.max_set_reps

    assigns =
      assign(assigns,
        stepper: %{
          field: "sets",
          value: set_size_value(current),
          unit: if(current, do: "reps a set", else: "a set"),
          label: "Most reps in one set",
          at_min?: current == hd(options),
          at_max?: is_nil(current),
          hint: "The longest run of reps before a rest"
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
          hint: split(params, params.pace)
        }
      )

    ~H"""
    <.stepper {@stepper} />
    """
  end

  attr(:field, :string, required: true)
  attr(:text, :string, required: true)
  attr(:value, :string, required: true)

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
    </button>
    """
  end

  attr(:field, :string, required: true)
  attr(:value, :any, required: true)
  attr(:unit, :string, required: true)
  attr(:label, :string, required: true)
  attr(:at_min?, :boolean, required: true)
  attr(:at_max?, :boolean, required: true)
  attr(:hint, :string, default: nil)

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
          <span
            id={"studio-#{@field}-value"}
            class={["studio-step-number", String.length(to_string(@value)) > 5 && "studio-step-text"]}
          >
            {@value}
          </span>
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
      <p :if={@hint} class="studio-step-hint">{@hint}</p>
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

  # A request on its way from the screen of choices has no box to write in.
  defp new_sending?(state),
    do: state.authoring_stage == :new and state.busy? and state.new_step != :request

  # Where you write. It is docked
  # above the keyboard (see the ChatDock hook), so it stays within reach as the thread grows.
  defp dock(assigns) do
    state = assigns.state
    proposed? = state.authoring_stage == :review
    visible? = not wizard?(state) and not new_sending?(state) and state.authoring_stage != :saved

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
              maxlength={if(edit?(@state), do: "500", else: "300")}
              class="composer-input"
              disabled={@state.busy?}
              phx-mounted={@state.authoring_stage == :new && JS.focus()}
            />
            <div class="composer-bar">
              <button
                id="home-edit-send"
                type="submit"
                class={["composer-send", @send_always? && "composer-send-ready"]}
                aria-label="Send"
                title="Send"
                disabled={@state.busy?}
              >
                <span :if={@state.busy?} class="composer-stop" aria-hidden="true"></span>
                <.icon :if={not @state.busy?} name="hero-arrow-turn-down-left" class="size-5" />
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
  defp placeholder(%{editing_source: nil}), do: "Additional request"
  defp placeholder(_state), do: "What should change?"

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

  # What reps at a pace come to: the time spent moving, and what is left to recover.
  defp split(params, pace) do
    seconds = duration_seconds(params)

    case NewDefaults.budget(params.reps, pace, seconds) do
      {moving, recovering} ->
        "#{CreationParameters.duration_label(moving)} moving · #{CreationParameters.duration_label(recovering)} recovering"

      nil ->
        nil
    end
  end

  defp set_size_value(nil), do: "No limit"
  defp set_size_value(size), do: size

  defp set_size_label(nil), do: "No limit"
  defp set_size_label(size), do: "Up to #{size}"

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
