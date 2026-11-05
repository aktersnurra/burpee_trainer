defmodule BurpeeTrainerWeb.HomeStudioComponents do
  @moduledoc """
  The studio: Edit and New as a chat, in place of Home. Edit opens on today's workout as a
  card and a box to write in; New opens on a form of what to make. A proposal arrives as a
  new card with Save and Run; back leaves without a change. See `docs/specs/2026-10-29-design-chat-design.md`.
  """
  use BurpeeTrainerWeb, :html

  alias BurpeeTrainer.Coach.NewDefaults
  alias BurpeeTrainer.Workouts.Shape

  alias BurpeeTrainerWeb.{CreationParameters, HomeWorkoutComponents}

  @doc "Whether Home gives way to the studio."
  def studio?(state), do: state.authoring_stage in [:new, :editing, :review]

  defp edit?(state), do: not is_nil(state.editing_source)

  defp heading(state), do: if(edit?(state), do: "Edit workout", else: "New workout")

  # New's form until it is sent; from then on the thread.
  defp form?(state), do: state.authoring_stage == :new and not state.busy?

  attr(:state, :map, required: true)

  def studio(assigns) do
    ~H"""
    <section id="home-studio" class="studio" data-stage={@state.authoring_stage}>
      <.header state={@state} />
      <h1 :if={not edit?(@state)} id="home-authoring-heading" class="studio-title">
        {heading(@state)}
      </h1>
      <.new_form :if={form?(@state)} state={@state} />
      <ol
        :if={not form?(@state)}
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

  # Back: from a proposal on screen, home with it as today's workout; otherwise out of Edit and
  # out of New's form, and from New's request in flight back to the form. Edit's is a Close.
  defp header(assigns) do
    assigns = assign(assigns, back: back(assigns.state), close?: edit?(assigns.state))

    ~H"""
    <header class="studio-header">
      <button
        id={@back.id}
        type="button"
        class="studio-back"
        data-vt={@back.vt}
        data-vt-from={@back.id == "home-request-keep" && "#studio-proposal .studio-card-name"}
        aria-label={if(@close?, do: "Close", else: @back.label)}
        title={if(@close?, do: "Close", else: "Back")}
        phx-click={@back.click}
      >
        <%!-- Edit closes; New rises over Home, so leaving it points down, and a step back in New
             points back. --%>
        <.icon
          name={
            cond do
              @close? -> "hero-x-mark"
              @back.vt == "drop" -> "hero-chevron-down"
              true -> "hero-chevron-left"
            end
          }
          class="size-5"
        />
      </button>
      <%!-- The title is the workout: in Edit its name, below; New's stands under the bar. --%>
      <h1 :if={edit?(@state)} id="home-authoring-heading" class="sr-only">{heading(@state)}</h1>
    </header>
    """
  end

  # What Back does here: keep the proposal on screen, leave, or step back to New's form.
  defp back(%{authoring_stage: :review, pending_request: %{}, busy?: false}),
    do: %{
      id: "home-request-keep",
      label: "Keep this workout",
      vt: "drop",
      click: JS.push("keep_workout_request") |> JS.focus(to: "#home-summary")
    }

  defp back(state) do
    if edit?(state) or form?(state),
      do: %{
        id: "home-request-abort",
        label: if(edit?(state), do: "Cancel edit", else: "Cancel new workout"),
        vt: "drop",
        click: JS.push("abort_new_workout") |> JS.focus(to: "#home-summary")
      },
      else: %{
        id: "studio-back",
        label: "Back to the form",
        vt: nil,
        click: JS.push("back_new_step")
      }
  end

  ## Edit

  attr(:state, :map, required: true)

  defp edit_thread(assigns) do
    state = assigns.state
    proposed? = state.authoring_stage == :review and not is_nil(state.pending_request)
    asked? = proposed? or state.busy?

    assigns = assign(assigns, proposed?: proposed?, asked?: asked?)

    ~H"""
    <%!-- One workout on screen: today's until you ask, then only what the coach makes of it. --%>
    <li :if={not @asked?} class="studio-msg studio-coach">
      <.card
        id="studio-source"
        name={@state.home_selection.plan.name}
        seconds={@state.home_selection.plan.target_duration_sec}
        reps={@state.home_selection.plan.target_reps}
        shape={Shape.describe(@state.home_selection.plan.definition_json)}
        rows={@state.inspection_rows}
        expanded={@state.expanded_groups}
      />
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
        shape={Shape.describe(@definition)}
        rows={@state.review_inspection_rows}
        compare={compare(@state)}
        was={was(@state)}
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
          id="home-request-run"
          type="button"
          class="studio-pill studio-pill-primary"
          phx-click="run_workout_request"
          disabled={@state.busy?}
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
  defp compare(state) do
    case Map.get(state, :previous) do
      %{rows: rows} -> rows
      nil -> if edit?(state), do: state.inspection_rows
    end
  end

  defp was(state) do
    case Map.get(state, :previous) do
      %{reps: reps, seconds: seconds, definition: definition} ->
        %{reps: reps, seconds: seconds, shape: Shape.describe(definition)}

      nil ->
        if edit?(state) do
          plan = state.home_selection.plan

          %{
            reps: plan.target_reps,
            seconds: plan.target_duration_sec,
            shape: Shape.describe(plan.definition_json)
          }
        end
    end
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
  attr(:shape, :string, default: nil)
  attr(:rows, :list, default: [])
  attr(:compare, :any, default: nil)
  attr(:was, :map, default: nil)
  attr(:expanded, :any, default: MapSet.new())

  # A workout, as the coach shows it: its name, its totals, a line on why, its structure as a
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
      <p :if={@note} class="studio-card-note">{@note}</p>
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

  attr(:state, :map, required: true)

  defp new_thread(assigns) do
    ~H"""
    <.proposal_thread state={@state} />
    """
  end

  attr(:state, :map, required: true)

  # Everything New asks, on one screen: the burpee as two words, duration and reps as big
  # numbers, the rest folded under More; Create sits at the foot, within the thumb's reach.
  defp new_form(assigns) do
    params = assigns.state.workout_parameters
    remaining = assigns.state.slot && assigns.state.slot.remaining_sec
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
        budget: split(params, params.pace),
        more: more_summary(params)
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
          hint={@budget}
        />
      </div>
      <%!-- What most workouts leave as suggested, folded under one line that shows it. The
           fields stay in the form while folded, so what they hold is always sent. --%>
      <button
        id="studio-more"
        type="button"
        class="studio-more"
        aria-expanded="false"
        aria-controls="studio-more-fields"
        phx-click={
          JS.toggle(to: "#studio-more-fields", display: "grid")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
      >
        <span class="sr-only">More: </span>
        <span id="studio-more-summary" class="studio-more-summary">
          {@more}<.icon name="hero-chevron-down" class="studio-more-chevron size-4" />
        </span>
      </button>
      <div id="studio-more-fields" class="studio-more-fields" style="display: none">
        <div class="studio-fields">
          <.segment
            field="pacing_style"
            label="Style"
            value={@params.pacing_style}
            options={[{"Even", "even"}, {"Unbroken", "unbroken"}]}
          />
          <.number
            :if={@params.pacing_style == "unbroken"}
            field="sets"
            label="Max set"
            unit="reps"
            value={@params.max_set_reps}
            placeholder="No limit"
            down?={not @sets_at_min?}
            up?={not is_nil(@params.max_set_reps)}
          />
          <.number
            field="pace"
            label="Pace"
            unit="s/rep"
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
      </div>
      <p :if={@state.local_error} id="home-adjustment-error" role="status" class="studio-error">
        {@state.local_error}
      </p>
      <button
        id="studio-create"
        type="submit"
        class="studio-pill studio-pill-primary studio-pill-wide"
      >
        Create workout
      </button>
    </form>
    """
  end

  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:options, :list, required: true)
  attr(:hero, :boolean, default: false)

  # A choice of two, side by side; the chosen one is filled. As the hero, two words, the
  # chosen one in ink.
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
  attr(:unit, :string, required: true)
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
        {@label}<span class="sr-only">, {@spoken_unit || @unit}</span>
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
          <span class="studio-number-unit" aria-hidden="true">{@unit}</span>
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

  attr(:state, :map, required: true)

  # Where you write. It is docked
  # above the keyboard (see the ChatDock hook), so it stays within reach as the thread grows.
  defp dock(assigns) do
    state = assigns.state

    assigns =
      assign(assigns,
        # New's form has its own note; the box is for Edit's asks and every follow-up.
        visible?: state.authoring_stage in [:editing, :review],
        # The coach's guesses at the next ask, for the proposal on screen; gone while it works.
        suggestions:
          if(state.authoring_stage == :review and not state.busy?,
            do: Map.get(state.pending_request, :suggestions, []),
            else: []
          ),
        event: event(state),
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
            />
            <div class="composer-bar">
              <button
                id="home-edit-send"
                type="submit"
                class="composer-send"
                aria-label="Send"
                title="Send"
                disabled={@state.busy?}
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
  defp event(%{authoring_stage: :review}), do: "refine_workout"
  defp event(_state), do: "review_current_edit"

  defp placeholder(%{authoring_stage: :review}), do: "Change anything else?"
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

  # The folded fields in a line: style, then a set's limit if there is one, then pace.
  defp more_summary(params) do
    style = if params.pacing_style == "unbroken", do: "Unbroken", else: "Even"
    sets = params.pacing_style == "unbroken" && params.max_set_reps
    pace = "#{format_pace(params.pace)} s/rep"
    [style, sets && "sets of #{sets}", pace] |> Enum.filter(& &1) |> Enum.join(" · ")
  end

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
