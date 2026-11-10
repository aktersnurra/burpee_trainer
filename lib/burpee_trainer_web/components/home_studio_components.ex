defmodule BurpeeTrainerWeb.HomeStudioComponents do
  @moduledoc """
  The studio: Edit and New as a chat, in place of Home. Edit opens on today's workout as a
  card and a box to write in; New opens on a form of what to make. The coach's reason streams
  in as it is written, then the proposal arrives as a card with Save and Run; X leaves without
  a change. See `docs/specs/2026-10-29-design-chat-design.md`.
  """
  use BurpeeTrainerWeb, :html

  alias BurpeeTrainer.Coach.NewDefaults
  alias BurpeeTrainer.Workouts.Shape

  alias BurpeeTrainerWeb.{CreationParameters, HomeWorkoutComponents, NewWorkoutForm}

  @doc "Whether Home gives way to the studio."
  def studio?(authoring_stage), do: authoring_stage in [:new, :editing, :review]

  defp edit?(editing_source), do: not is_nil(editing_source)

  defp heading(editing_source),
    do: if(edit?(editing_source), do: "Edit workout", else: "New workout")

  # New's form until it is sent; from then on the thread.
  defp form?(authoring_stage, busy?), do: authoring_stage == :new and not busy?

  # In Edit, whether the coach was asked: a proposal is on screen or on its way.
  defp asked?(authoring_stage, pending_request, busy?),
    do: (authoring_stage == :review and not is_nil(pending_request)) or busy?

  attr(:authoring_stage, :atom, required: true)
  attr(:editing_source, :any, required: true)
  attr(:busy?, :boolean, required: true)
  attr(:local_error, :any, required: true)
  attr(:home_selection, :any, required: true)
  attr(:inspection_rows, :list, required: true)
  attr(:review_inspection_rows, :list, required: true)
  attr(:expanded_groups, :any, required: true)
  attr(:pending_request, :any, required: true)
  attr(:pending_turn, :any, required: true)
  attr(:design_turns, :list, required: true)
  attr(:streaming?, :boolean, required: true)
  attr(:reply_pieces, :any, required: true)
  attr(:previous, :any, required: true)
  attr(:instruction, :any, required: true)
  attr(:workout_parameters, :any, required: true)
  attr(:slot, :any, required: true)
  attr(:adjustment_form, :any, required: true)

  def studio(assigns) do
    ~H"""
    <section id="home-studio" class="studio" data-stage={@authoring_stage}>
      <.header editing_source={@editing_source} authoring_stage={@authoring_stage} busy?={@busy?} />
      <h1 :if={not edit?(@editing_source)} id="home-authoring-heading" class="studio-title">
        {heading(@editing_source)}
      </h1>
      <.new_form
        :if={form?(@authoring_stage, @busy?)}
        workout_parameters={@workout_parameters}
        slot={@slot}
        local_error={@local_error}
      />
      <ol
        :if={not form?(@authoring_stage, @busy?)}
        id="studio-thread"
        class="studio-thread"
        aria-label="Conversation with the coach"
      >
        <%!-- One workout on screen: today's until you ask, then only what the coach makes of it. --%>
        <li
          :if={edit?(@editing_source) and not asked?(@authoring_stage, @pending_request, @busy?)}
          class="studio-msg studio-coach"
        >
          <.card
            id="studio-source"
            name={@home_selection.plan.name}
            seconds={@home_selection.plan.target_duration_sec}
            reps={@home_selection.plan.target_reps}
            shape={Shape.describe(@home_selection.plan.definition_json)}
            rows={@inspection_rows}
            expanded={@expanded_groups}
          />
        </li>
        <.proposal_thread
          :if={not edit?(@editing_source) or asked?(@authoring_stage, @pending_request, @busy?)}
          authoring_stage={@authoring_stage}
          editing_source={@editing_source}
          busy?={@busy?}
          home_selection={@home_selection}
          inspection_rows={@inspection_rows}
          review_inspection_rows={@review_inspection_rows}
          expanded_groups={@expanded_groups}
          pending_request={@pending_request}
          pending_turn={@pending_turn}
          design_turns={@design_turns}
          streaming?={@streaming?}
          reply_pieces={@reply_pieces}
          previous={@previous}
          instruction={@instruction}
          workout_parameters={@workout_parameters}
        />
        <li :if={@local_error} id="home-adjustment-error" role="status" class="studio-error">
          {@local_error}
        </li>
      </ol>
      <.dock
        adjustment_form={@adjustment_form}
        authoring_stage={@authoring_stage}
        editing_source={@editing_source}
        busy?={@busy?}
        pending_request={@pending_request}
        pending_turn={@pending_turn}
        design_turns={@design_turns}
      />
    </section>
    """
  end

  attr(:editing_source, :any, required: true)
  attr(:authoring_stage, :atom, required: true)
  attr(:busy?, :boolean, required: true)

  # Close: out of the studio with nothing changed, whatever is on screen (Save keeps a proposal).
  # Only the step back from New's request in flight to its form points back.
  defp header(assigns) do
    form? = form?(assigns.authoring_stage, assigns.busy?)

    back =
      back(edit?(assigns.editing_source) or form? or assigns.authoring_stage == :review)

    assigns = assign(assigns, back: back, close?: back.id != "studio-back", form?: form?)

    ~H"""
    <header class="studio-header">
      <%!-- New's form closes from its foot; the bar keeps the top row's height. --%>
      <button
        :if={not @form?}
        id={@back.id}
        type="button"
        class="studio-back"
        data-vt={@back.vt}
        aria-label={if(@close?, do: "Close", else: @back.label)}
        title={if(@close?, do: "Close", else: "Back")}
        phx-click={@back.click}
      >
        <.icon name={if(@close?, do: "hero-x-mark", else: "hero-chevron-left")} class="size-5" />
      </button>
      <%!-- The title is the workout: in Edit its name, below; New's stands under the bar. --%>
      <h1 :if={edit?(@editing_source)} id="home-authoring-heading" class="sr-only">
        {heading(@editing_source)}
      </h1>
    </header>
    """
  end

  # What the header's button does here: leave, or step back to New's form.
  # (New's form leaves by the X at its foot, which does the same.)
  defp back(true = _leave?),
    do: %{
      id: "home-request-abort",
      vt: "drop",
      click: JS.push("abort_new_workout") |> JS.focus(to: "#home-summary")
    }

  defp back(false = _leave?),
    do: %{
      id: "studio-back",
      label: "Back to the form",
      vt: nil,
      click: JS.push("back_new_step")
    }

  ## The thread

  attr(:authoring_stage, :atom, required: true)
  attr(:editing_source, :any, required: true)
  attr(:busy?, :boolean, required: true)
  attr(:home_selection, :any, required: true)
  attr(:inspection_rows, :list, required: true)
  attr(:review_inspection_rows, :list, required: true)
  attr(:expanded_groups, :any, required: true)
  attr(:pending_request, :any, required: true)
  attr(:pending_turn, :any, required: true)
  attr(:design_turns, :list, required: true)
  attr(:streaming?, :boolean, required: true)
  attr(:reply_pieces, :any, required: true)
  attr(:previous, :any, required: true)
  attr(:instruction, :any, required: true)
  attr(:workout_parameters, :any, required: true)

  # The asks so far and what each became, then the proposal now on screen, then the ask
  # in flight, each below the last.
  defp proposal_thread(assigns) do
    assigns =
      assign(assigns,
        first_busy?:
          assigns.busy? and is_nil(assigns.pending_turn) and assigns.authoring_stage != :review,
        refining?: is_binary(assigns.pending_turn)
      )

    ~H"""
    <%= for turn <- @design_turns do %>
      <li class="studio-msg studio-you">
        <p class="studio-bubble">{turn.instruction}</p>
      </li>
      <li class="studio-msg studio-coach">
        <p class="studio-turn">
          {turn.name} · {minutes(turn.duration_sec)} min · {turn.reps} reps
        </p>
      </li>
    <% end %>
    <li
      :if={ask(@editing_source, @design_turns, @instruction, @workout_parameters) != ""}
      class="studio-msg studio-you"
    >
      <p id="home-design-ask" class="studio-bubble">
        {ask(@editing_source, @design_turns, @instruction, @workout_parameters)}
      </p>
    </li>
    <li :if={@first_busy?} class="studio-msg studio-coach">
      <.writing streaming?={@streaming?} pieces={@reply_pieces} />
    </li>
    <li :if={@authoring_stage == :review and @pending_request} class="studio-msg studio-coach">
      <%!-- What it is read against comes from the tracked values, so a reply streaming in
           below does not send the card again. --%>
      <.proposal
        pending_request={@pending_request}
        rows={@review_inspection_rows}
        expanded_groups={@expanded_groups}
        busy?={@busy?}
        compare={compare(@previous, @editing_source, @inspection_rows)}
        was={was(@previous, @editing_source, @home_selection)}
      />
    </li>
    <li :if={@refining?} class="studio-msg studio-you">
      <p id="home-design-pending" class="studio-bubble">{@pending_turn}</p>
    </li>
    <li :if={@refining?} class="studio-msg studio-coach">
      <.writing streaming?={@streaming?} pieces={@reply_pieces} />
    </li>
    <li
      :if={@authoring_stage == :review and @busy? and not @refining?}
      class="studio-msg studio-coach"
    >
      <.working label="Saving…" />
    </li>
    """
  end

  # What was asked for the proposal on screen: your words in Edit and in a follow-up; New's
  # first ask is only what was written with its answers, which the screen before showed.
  defp ask(editing_source, design_turns, instruction, workout_parameters) do
    if edit?(editing_source) or design_turns != [],
      do: instruction,
      else: workout_parameters.note || ""
  end

  attr(:pending_request, :any, required: true)
  attr(:rows, :list, required: true)
  attr(:expanded_groups, :any, required: true)
  attr(:busy?, :boolean, required: true, doc: "stale while the coach works on what replaces it")
  attr(:compare, :any, required: true)
  attr(:was, :any, required: true)

  defp proposal(assigns) do
    assigns = assign(assigns, definition: assigns.pending_request.definition)

    ~H"""
    <div id="home-edit-review" class={["studio-proposal", @busy? && "studio-proposal-stale"]}>
      <p :if={@definition["rationale"]} id="studio-reply" class="studio-reply">
        {@definition["rationale"]}
      </p>
      <.card
        id="studio-proposal"
        name={@definition["name"]}
        seconds={@definition["target_duration_sec"]}
        reps={@definition["target_reps"]}
        shape={Shape.describe(@definition)}
        rows={@rows}
        compare={@compare}
        was={@was}
        expanded={@expanded_groups}
      />
      <p
        :if={@pending_request.request.timed_rests != []}
        id="home-edit-review-pauses"
        class="studio-turn"
      >
        {pauses_label(@pending_request.request.timed_rests)}
      </p>
      <%!-- What to do with it sits right under the card it is about: Save makes it today's
           workout and goes home with it; Run does that and starts it, with the camera and
           warmup choices this device remembers from Home. --%>
      <div id="home-chat-actions" class="studio-actions">
        <button
          id="home-request-save"
          type="button"
          class="studio-pill"
          phx-click={JS.push("keep_workout_request") |> JS.focus(to: "#home-summary")}
          data-vt="drop"
          data-vt-from="#studio-proposal .studio-card-name"
          disabled={@busy?}
          aria-label="Save"
          title="Save"
        >
          <.icon name="hero-check" class="size-6" />
        </button>
        <button
          id="home-request-run"
          type="button"
          class="studio-pill studio-pill-primary"
          phx-click="run_workout_request"
          disabled={@busy?}
          aria-label="Run"
          title="Run"
        >
          <.icon name="hero-play-solid" class="size-6" />
        </button>
      </div>
    </div>
    """
  end

  # What a proposal is read against: the one it replaced, else the workout Edit began from.
  defp compare(previous, editing_source, inspection_rows) do
    case previous do
      %{rows: rows} -> rows
      nil -> if edit?(editing_source), do: inspection_rows
    end
  end

  defp was(previous, editing_source, home_selection) do
    case previous do
      %{reps: reps, seconds: seconds, definition: definition} ->
        %{reps: reps, seconds: seconds, shape: Shape.describe(definition)}

      nil ->
        if edit?(editing_source) do
          plan = home_selection.plan

          %{
            reps: plan.target_reps,
            seconds: plan.target_duration_sec,
            shape: Shape.describe(plan.definition_json)
          }
        end
    end
  end

  attr(:streaming?, :boolean, required: true)
  attr(:pieces, :any, required: true)

  # The coach at work: its loader until its first word, then what it has written so far, a
  # piece at a time (`ReplyStream`).
  defp writing(%{streaming?: true} = assigns) do
    ~H"""
    <p
      id="studio-streaming"
      class="studio-reply chat-streaming"
      aria-busy="true"
      phx-update="stream"
    >
      <span :for={{id, piece} <- @pieces} id={id}>{piece.text}</span>
    </p>
    """
  end

  defp writing(assigns) do
    ~H"""
    <.working />
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
  attr(:shape, :string, default: nil)
  attr(:rows, :list, default: [])
  attr(:compare, :any, default: nil)
  attr(:was, :map, default: nil)
  attr(:expanded, :any, default: MapSet.new())

  # A workout, as the coach shows it: its name, its totals, its structure as a
  # sentence (with the one it replaced struck through when that changed), and its table.
  defp card(assigns) do
    assigns =
      assign(assigns,
        was_shape:
          changed?(assigns.was, :shape, assigns.shape) &&
            was_shape(assigns.was.shape, assigns.shape)
      )

    ~H"""
    <article id={@id} class="studio-card">
      <h2 class="studio-card-name">{@name}</h2>
      <p class="studio-card-totals">
        <span class="studio-chip">
          <.diff
            changed?={changed?(@was, :seconds, round(@seconds))}
            was={@was && minutes(@was.seconds)}
            now={minutes(@seconds)}
          /> min
        </span>
        <span class="studio-chip">
          <.diff changed?={changed?(@was, :reps, @reps)} was={@was && @was.reps} now={@reps} /> reps
        </span>
      </p>
      <p :if={@shape} class="home-shape">
        {@shape}
        <s :if={@was_shape} class="diff-was">was {@was_shape}</s>
      </p>
      <div class="studio-card-table">
        <HomeWorkoutComponents.inspection
          rows={@rows}
          compare={@compare}
          expanded={@expanded}
        />
      </div>
    </article>
    """
  end

  defp changed?(nil, _key, _value), do: false
  defp changed?(was, key, value), do: Map.get(was, key) != value

  # The first part of the old sentence the new one no longer says: `5 sets of 3`.
  defp was_shape(was, now) do
    parts = String.split(now, " · ")
    was |> String.split(" · ") |> Enum.find(&(&1 not in parts))
  end

  attr(:changed?, :boolean, required: true)
  attr(:was, :any, required: true)
  attr(:now, :any, required: true)

  # What a proposal changed: the old value struck through, the new one highlighted.
  defp diff(assigns) do
    ~H"""
    <%= if @changed? do %>
      <s class="diff-was">{@was}</s> <mark class="diff-now">{@now}</mark>
    <% else %>
      {@now}
    <% end %>
    """
  end

  ## New

  attr(:workout_parameters, :any, required: true)
  attr(:slot, :any, required: true)
  attr(:local_error, :any, required: true)

  # Everything New asks, on one screen: the burpee as two pills, duration and reps as big
  # numbers, the structure they make as a sentence, then the rest as quiet rows labelled like
  # settings, the request, and the foot: X to leave, ✓ to create.
  defp new_form(assigns) do
    params = assigns.workout_parameters
    remaining = assigns.slot && assigns.slot.remaining_sec
    durations = NewDefaults.durations(remaining)
    minutes = duration_minutes(params)
    seconds = duration_seconds(params)
    set_sizes = NewDefaults.set_sizes(params.reps)

    assigns =
      assign(assigns,
        params: params,
        duration: %{
          value: minutes,
          at_min?: minutes <= hd(durations),
          at_max?: minutes >= List.last(durations)
        },
        remaining: remaining,
        at_max_reps?: params.reps >= NewDefaults.max_reps(params.pace, seconds),
        sets_at_min?: params.max_set_reps == hd(set_sizes),
        at_max_pace?: params.reps * (params.pace + 0.5) > seconds,
        min_pace: NewDefaults.min_pace(String.to_existing_atom(params.burpee_type)),
        shape: NewWorkoutForm.shape(params),
        abort: back(true)
      )

    ~H"""
    <form
      id="studio-new-form"
      class="studio-form studio-form-hero"
      phx-change="change_new_workout"
      phx-submit="send_new_workout"
      novalidate
    >
      <.segment
        field="burpee_type"
        label="Burpee"
        value={@params.burpee_type}
        options={[{"Six-count", "six_count"}, {"Navy SEAL", "navy_seal"}]}
        hero
      />
      <div class="studio-hero-numbers">
        <.number
          hero
          field="duration"
          label="Duration"
          unit="min"
          spoken_unit="minutes"
          value={@duration.value}
          down?={not @duration.at_min?}
          up?={not @duration.at_max?}
          hint={@remaining && "#{div(@remaining, 60)} min left this week"}
        />
        <.number
          hero
          field="reps"
          label="Reps"
          unit="reps"
          value={@params.reps}
          down?={@params.reps > 5}
          up?={not @at_max_reps?}
        />
      </div>
      <p :if={@shape} id="studio-shape" class="home-shape">{@shape}</p>
      <div class="studio-fields">
        <.segment
          field="pacing_style"
          label="Sets"
          value={@params.pacing_style}
          options={[{"Even", "even"}, {"Unbroken", "unbroken"}]}
        />
        <.number
          :if={@params.pacing_style == "unbroken"}
          field="sets"
          label="Set size"
          spoken_unit="reps"
          value={@params.max_set_reps}
          placeholder="No limit"
          down?={not @sets_at_min?}
          up?={not is_nil(@params.max_set_reps)}
        />
        <.number
          field="pace"
          label="Pace"
          unit="s"
          spoken_unit="seconds per rep"
          value={format_pace(@params.pace)}
          step="0.1"
          inputmode="decimal"
          down?={@params.pace > @min_pace}
          up?={not @at_max_pace?}
        />
      </div>
      <div class="studio-note composer">
        <label for="studio-note" class="sr-only">Anything else? (optional)</label>
        <textarea
          id="studio-note"
          name="new[note]"
          rows="2"
          maxlength="300"
          placeholder="Anything else? Front-load the reps, say"
          phx-debounce="300"
        >{@params.note}</textarea>
      </div>
      <p :if={@local_error} id="home-adjustment-error" role="status" class="studio-error">
        {@local_error}
      </p>
      <div class="studio-foot">
        <button
          id={@abort.id}
          type="button"
          class="studio-foot-close"
          data-vt={@abort.vt}
          aria-label="Close"
          title="Close"
          phx-click={@abort.click}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <button
          id="studio-create"
          type="submit"
          class="studio-pill studio-pill-primary"
          aria-label="Create"
          title="Create"
        >
          <.icon name="hero-check" class="size-6" />
        </button>
      </div>
    </form>
    """
  end

  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:options, :list, required: true)
  attr(:hero, :boolean, default: false)

  # A choice of two, as pills side by side; the chosen one wears the picked type's tint. As the
  # hero, the pick stands alone; otherwise it is a row with its label.
  defp segment(assigns) do
    ~H"""
    <fieldset class={if @hero, do: "studio-hero-segment", else: "studio-row"}>
      <legend class={if @hero, do: "sr-only", else: "studio-row-label"}>{@label}</legend>
      <div class="studio-segment">
        <label :for={{text, value} <- @options} class="studio-segment-option">
          <input
            id={"studio-#{@field}-#{value}"}
            type="radio"
            name={"new[#{@field}]"}
            value={value}
            checked={@value == value}
          />
          <span>{text}</span>
        </label>
      </div>
    </fieldset>
    """
  end

  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:unit, :string, default: nil)
  attr(:spoken_unit, :string, default: nil)
  attr(:value, :any, required: true)
  attr(:placeholder, :string, default: nil)
  attr(:step, :string, default: "1")
  attr(:inputmode, :string, default: "numeric")
  attr(:down?, :boolean, required: true)
  attr(:up?, :boolean, required: true)
  attr(:hint, :string, default: nil)
  attr(:hero, :boolean, default: false)

  # A number to type, or to move a step at a time with the buttons beside it; held, a button
  # keeps stepping (the HoldRepeat hook). A value typed is sent when the typing pauses or the
  # field is left.
  defp number(assigns) do
    ~H"""
    <div class={if @hero, do: "studio-hero-number", else: "studio-row"}>
      <label for={"studio-#{@field}"} class={if @hero, do: "sr-only", else: "studio-row-label"}>
        {@label}<span :if={@spoken_unit || @unit} class="sr-only">, {@spoken_unit || @unit}</span>
      </label>
      <div id={"studio-#{@field}-stepper"} class="studio-number" phx-hook="HoldRepeat">
        <button
          id={"studio-#{@field}-down"}
          type="button"
          class="studio-number-button"
          phx-click="step_workout_value"
          phx-value-field={@field}
          phx-value-dir="down"
          aria-label={"Less #{String.downcase(@label)}"}
          disabled={not @down?}
        >
          <.icon name="hero-minus" class="size-4" />
        </button>
        <span class="studio-number-field">
          <input
            id={"studio-#{@field}"}
            type="text"
            name={"new[#{@field}]"}
            value={@value}
            placeholder={@placeholder}
            inputmode={@inputmode}
            autocomplete="off"
            class="studio-number-input"
            phx-debounce="600"
          />
          <span :if={@unit} class="studio-number-unit" aria-hidden="true">{@unit}</span>
        </span>
        <button
          id={"studio-#{@field}-up"}
          type="button"
          class="studio-number-button"
          phx-click="step_workout_value"
          phx-value-field={@field}
          phx-value-dir="up"
          aria-label={"More #{String.downcase(@label)}"}
          disabled={not @up?}
        >
          <.icon name="hero-plus" class="size-4" />
        </button>
      </div>
      <p :if={@hint} id={"studio-#{@field}-hint"} class="studio-row-hint">{@hint}</p>
    </div>
    """
  end

  ## Dock

  attr(:adjustment_form, :any, required: true)
  attr(:authoring_stage, :atom, required: true)
  attr(:editing_source, :any, required: true)
  attr(:busy?, :boolean, required: true)
  attr(:pending_request, :any, required: true)
  attr(:pending_turn, :any, required: true)
  attr(:design_turns, :list, required: true)

  # Where you write. It is docked
  # above the keyboard (see the ChatDock hook), so it stays within reach as the thread grows.
  defp dock(assigns) do
    assigns =
      assign(assigns,
        # New's form has its own note; the box is for Edit's asks and every follow-up.
        visible?: assigns.authoring_stage in [:editing, :review],
        # The coach's guesses at the next ask, for the proposal on screen; gone while it works.
        suggestions:
          if(assigns.authoring_stage == :review and not assigns.busy?,
            do: Map.get(assigns.pending_request, :suggestions, []),
            else: []
          ),
        event: event(assigns.authoring_stage),
        placeholder: placeholder(assigns.authoring_stage)
      )

    ~H"""
    <div
      :if={@visible?}
      id="home-chat-dock"
      class="chat-dock"
      phx-hook="ChatDock"
      data-version={version(@authoring_stage, @design_turns, @pending_turn, @busy?)}
      data-scroll-to={scroll_target(@pending_turn)}
    >
      <div class="chat-dock-inner">
        <%!-- Just above the box: a tap sends one, as if it were typed. --%>
        <div
          :if={@suggestions != []}
          id="studio-suggestions"
          class="studio-suggestions"
          role="group"
          aria-label="Suggested changes"
          data-no-swipe
        >
          <button
            :for={{text, i} <- Enum.with_index(@suggestions)}
            id={"studio-suggestion-#{i}"}
            type="button"
            class="studio-pill studio-suggestion"
            phx-click={JS.push("refine_workout", value: %{home_adjustment: %{instruction: text}})}
          >
            {text}
          </button>
        </div>
        <.form
          for={@adjustment_form}
          id="home-edit-form"
          class="home-authoring-form"
          phx-submit={@event}
          phx-change="change_current_edit"
          aria-busy={to_string(@busy?)}
        >
          <div class="composer">
            <.input
              field={@adjustment_form[:instruction]}
              id="home-edit-instruction"
              type="textarea"
              label={
                if(edit?(@editing_source), do: "What do you want to change?", else: "Anything else?")
              }
              placeholder={@placeholder}
              rows="1"
              maxlength={if(edit?(@editing_source), do: "500", else: "300")}
              class="composer-input"
              disabled={@busy?}
            />
            <div class="composer-bar">
              <button
                id="home-edit-send"
                type="submit"
                class="composer-send"
                aria-label="Send"
                title="Send"
                disabled={@busy?}
              >
                <span class="composer-send-dot" aria-hidden="true">
                  <.icon name="hero-arrow-up-mini" class="size-5" />
                </span>
              </button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    <div :if={@visible?} id="home-chat-end" class="chat-dock-spacer" aria-hidden="true"></div>
    """
  end

  # The first message of an edit starts the design; every later one refines the proposal.
  defp event(:review), do: "refine_workout"
  defp event(_authoring_stage), do: "review_current_edit"

  defp placeholder(:review), do: "Change anything else?"
  defp placeholder(_authoring_stage), do: "What should change?"

  # The newest thing said: your pending message while the coach works, else your last one.
  defp scroll_target(turn) when is_binary(turn), do: "#home-design-pending"
  defp scroll_target(_no_turn), do: "#home-design-ask"

  defp version(authoring_stage, design_turns, pending_turn, busy?),
    do: "#{authoring_stage}:#{length(design_turns)}:#{is_binary(pending_turn)}:#{busy?}"

  ## Labels

  defp minutes(seconds), do: div(round(seconds), 60)

  defp duration_seconds(params) do
    {:ok, seconds} = CreationParameters.duration_seconds(params.duration)
    seconds
  end

  defp duration_minutes(params), do: div(duration_seconds(params), 60)

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
