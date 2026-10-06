defmodule BurpeeTrainerWeb.HomeCoachComponents do
  @moduledoc "Small recommendation-first presentation primitives for Home."

  use BurpeeTrainerWeb, :html

  attr(:id, :string, required: true)
  attr(:return_focus?, :boolean, default: false)

  def entry(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={if(@id == "history-coach-open", do: ~p"/coach?from=history", else: ~p"/coach?from=home")}
      class="home-coach-entry"
      phx-mounted={@return_focus? && JS.focus(to: "#" <> @id)}
    >
      <.icon name="hero-chat-bubble-left-right" class="size-5" />
      <span>Coach</span>
    </.link>
    """
  end

  attr(:state, :map, required: true)

  def panel(assigns) do
    ~H"""
    <section
      id="home-coach-panel"
      class="home-coach-panel"
      aria-label="Coach"
      phx-window-keydown="close_coach"
      phx-key="Escape"
      phx-mounted={JS.focus(to: "#home-coach-heading")}
    >
      <button
        id="home-coach-back"
        type="button"
        class="home-state-action min-h-11 min-w-11"
        aria-label={
          if(@state.coach_return_to == "/history",
            do: "Back to History",
            else: "Back to workout"
          )
        }
        phx-click="close_coach"
      >
        <.icon name="hero-arrow-left" class="size-5" />
      </button>
      <h1 id="home-coach-heading" tabindex="-1" class="home-state-heading">Coach</h1>
      <section id="home-coach-summary" aria-label="Your summary">
        <p class="home-coach-baseline">
          {if(@state.current_level == :graduated,
            do: "Graduated",
            else:
              "Level " <>
                (@state.current_level
                 |> Atom.to_string()
                 |> String.replace_prefix("level_", "")
                 |> String.upcase())
          )}<span :if={@state.slot}> · {div(@state.slot.weekly_target_sec, 60)} min/week</span>
        </p>
        <p :if={@state.coach_summary != ""} class="home-coach-summary-text">{@state.coach_summary}</p>
      </section>
      <details
        id="history-coach-memory"
        class="history-coach-memory"
        open={@state.coach_details_open?}
      >
        <summary id="history-coach-memory-toggle" phx-click="coach_details_toggle">Details</summary>
        <div id="history-coach-entries" phx-update="stream">
          <p id="history-coach-empty" class="hidden only:block coach-guidance-empty">
            No entries.
          </p>
          <div
            :for={{dom_id, entry} <- @state.streams.coach_guidance_entries}
            id={dom_id}
            class="history-coach-entry"
          >
            <%= if @state.coach_guidance_edit_id == entry.id do %>
              <.form
                for={@state.coach_guidance_edit_form}
                id={"history-coach-edit-form-#{entry.id}"}
                phx-submit="coach_guidance_edit_save"
                phx-change="coach_guidance_edit_change"
                class="history-coach-edit-form"
              >
                <.input
                  field={@state.coach_guidance_edit_form[:text]}
                  id={"history-coach-edit-text-#{entry.id}"}
                  type="textarea"
                  label="Edit info"
                  rows="2"
                  maxlength="1000"
                  class="coach-guidance-input"
                  phx-mounted={JS.focus(to: "#history-coach-edit-text-#{entry.id}")}
                />
                <div class="history-coach-edit-actions">
                  <button
                    type="button"
                    id={"history-coach-edit-cancel-#{entry.id}"}
                    phx-click="coach_guidance_edit_cancel"
                    class="history-coach-remove"
                    aria-label="Cancel edit"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                  <button
                    type="submit"
                    id={"history-coach-edit-save-#{entry.id}"}
                    class="history-coach-remove"
                    aria-label="Save info"
                  >
                    <.icon name="hero-check" class="size-4" />
                  </button>
                </div>
              </.form>
            <% else %>
              <p class="history-coach-original">{entry.text}</p>
              <button
                id={"history-coach-edit-#{entry.id}"}
                type="button"
                aria-label={"Edit info #{entry.id}"}
                phx-click="coach_guidance_edit"
                phx-value-id={entry.id}
                class="history-coach-remove"
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
            <% end %>
            <button
              id={"history-coach-remove-#{entry.id}"}
              type="button"
              aria-label={"Remove coach guidance #{entry.id}"}
              title="Remove guidance"
              phx-click="coach_guidance_remove"
              phx-value-id={entry.id}
              class="history-coach-remove"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
        </div>
      </details>
      <.guidance_form
        id="home-coach-guidance-form"
        form={@state.coach_guidance_form}
        status={@state.coach_guidance_status}
      />
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:form, :any, required: true)
  attr(:status, :string, default: nil)
  attr(:memory_link?, :boolean, default: false)

  def guidance_form(assigns) do
    assigns = assign(assigns, :base_id, String.replace_suffix(assigns.id, "-form", ""))

    ~H"""
    <section id={"#{@id}-section"} class="coach-guidance" aria-label="Coach guidance">
      <.form
        for={@form}
        id={@id}
        phx-submit="coach_guidance_submit"
        phx-change="coach_guidance_change"
      >
        <div class="coach-guidance-row">
          <.input
            field={@form[:text]}
            id={"#{@base_id}-text"}
            type="textarea"
            label="New info"
            rows="2"
            maxlength="1000"
            placeholder="Add a goal or other info"
            class="coach-guidance-input"
          />
          <button
            id={"#{@base_id}-send"}
            type="submit"
            aria-label="Send to coach"
            title="Send to coach"
            phx-disable-with="Sending…"
            class="coach-guidance-send"
          >
            <.icon name="hero-arrow-up" class="size-5" />
          </button>
        </div>
      </.form>
      <p id={"#{@base_id}-status"} class="coach-guidance-status" role="status">{@status}</p>
      <.link
        :if={@memory_link?}
        id="home-coach-memory-link"
        patch={~p"/history"}
        class="coach-guidance-memory-link"
      >
        View coach memory in History
      </.link>
    </section>
    """
  end
end
