defmodule BurpeeTrainerWeb.WorkoutLibraryLive do
  @moduledoc "Durable published workouts and private authoring drafts."

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Coach, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.WorkoutLibraryComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    published = Workouts.list_library(user)
    drafts = Workouts.list_drafts(user)

    {:ok,
     socket
     |> assign(:create_form, request_form(:workout))
     |> assign(:refine_forms, refine_forms(drafts))
     |> assign(:start_client_session_id, Ecto.UUID.generate())
     |> stream(:published, published, dom_id: &"published-workout-#{&1.id}")
     |> stream(:drafts, drafts, dom_id: &"draft-workout-#{&1.id}")}
  end

  @impl true
  def handle_event("create", %{"workout" => %{"request" => request} = params}, socket) do
    case Coach.create_draft(socket.assigns.current_user, request) do
      {:ok, draft} ->
        {:noreply,
         socket
         |> assign(:create_form, request_form(:workout))
         |> put_refine_form(draft)
         |> stream_insert(:drafts, draft, at: 0)
         |> put_flash(:info, "Draft created. Review it before publishing.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:create_form, to_form(params, as: :workout))
         |> put_flash(:error, "Could not create a draft. Nothing was saved.")}
    end
  end

  def handle_event("create", _params, socket) do
    {:noreply, put_flash(socket, :error, "Describe the workout you want.")}
  end

  def handle_event(
        "refine",
        %{"id" => id, "refinement" => %{"request" => request}},
        socket
      ) do
    with {:ok, draft_id} <- parse_id(id),
         {:ok, draft} <- Coach.refine_draft(socket.assigns.current_user, draft_id, request) do
      {:noreply,
       socket
       |> put_refine_form(draft)
       |> stream_insert(:drafts, draft)
       |> put_flash(:info, "Draft refined.")}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Could not refine that draft. Nothing changed.")}
    end
  end

  def handle_event("copy", %{"id" => id}, socket) do
    with {:ok, plan_id} <- parse_id(id),
         {:ok, draft} <- Workouts.copy_to_draft(socket.assigns.current_user, plan_id) do
      {:noreply,
       socket
       |> put_refine_form(draft)
       |> stream_insert(:drafts, draft, at: 0)
       |> put_flash(:info, "Copy saved as a draft.")}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not copy that workout.")}
    end
  end

  def handle_event("publish", %{"id" => id}, socket) do
    with {:ok, draft_id} <- parse_id(id),
         {:ok, published} <- Workouts.publish_draft(socket.assigns.current_user, draft_id) do
      {:noreply,
       socket
       |> stream_delete(:drafts, published)
       |> stream_insert(:published, published, at: 0)
       |> drop_refine_form(published.id)
       |> put_flash(:info, "Workout published.")}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not publish that workout.")}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    with {:ok, plan_id} <- parse_id(id),
         {:ok, archived} <- Workouts.archive_plan(socket.assigns.current_user, plan_id) do
      {:noreply,
       socket
       |> stream_delete(:published, archived)
       |> put_flash(:info, "Workout archived.")}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not archive that workout.")}
    end
  end

  def handle_event("delete_draft", %{"id" => id}, socket) do
    with {:ok, draft_id} <- parse_id(id),
         {:ok, draft} <- Workouts.get_draft(socket.assigns.current_user, draft_id),
         :ok <- Workouts.delete_draft(socket.assigns.current_user, draft_id) do
      {:noreply,
       socket
       |> stream_delete(:drafts, draft)
       |> drop_refine_form(draft.id)
       |> put_flash(:info, "Draft deleted.")}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not delete that draft.")}
    end
  end

  def handle_event(
        "start",
        %{"id" => id, "client-session-id" => client_session_id},
        socket
      ) do
    with true <- client_session_id == socket.assigns.start_client_session_id,
         {:ok, plan_id} <- parse_id(id),
         {:ok, %WorkoutSession{} = session} <-
           Workouts.start_plan(socket.assigns.current_user, plan_id, client_session_id) do
      {:noreply, push_navigate(socket, to: ~p"/session/#{session.id}")}
    else
      _error -> {:noreply, put_flash(socket, :error, "That workout is no longer available.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_scope={assigns[:current_scope]}
      current_page={:library}
    >
      <div
        id="workout-library-page"
        class="session-surface mx-auto max-w-3xl space-y-10 pb-24 text-[var(--session-ink)]"
      >
        <header class="max-w-2xl space-y-3 px-1">
          <p class="text-sm font-medium text-[var(--session-muted)]">Workout library</p>
          <h1 class="text-4xl font-semibold tracking-[-0.055em] text-[var(--session-ink)] sm:text-5xl">
            Workouts worth repeating
          </h1>
          <p class="max-w-xl text-base leading-7 text-[var(--session-muted)]">
            Start a published workout, or describe a new one in plain language and review the draft first.
          </p>
        </header>

        <section class="rounded-3xl border border-[var(--session-border)] bg-[var(--session-surface)]/55 p-6 sm:p-8">
          <div class="mb-5 space-y-1">
            <h2 class="text-xl font-semibold text-[var(--session-ink)]">Create a workout</h2>
            <p class="text-sm text-[var(--session-muted)]">
              Describe the result. No setup builder required.
            </p>
          </div>
          <.form for={@create_form} id="workout-create-form" phx-submit="create" class="space-y-4">
            <.input
              field={@create_form[:request]}
              id="workout-create-request"
              type="textarea"
              label="What kind of workout do you want?"
              maxlength="500"
              rows="4"
              placeholder="A steady 20-minute six-count workout with short rests"
            />
            <button
              type="submit"
              phx-disable-with="Creating draft…"
              class="min-h-12 rounded-2xl bg-[var(--session-ink)] px-6 py-3 text-sm font-semibold text-[var(--session-bg)] transition hover:opacity-90"
            >
              Create draft
            </button>
          </.form>
        </section>

        <section class="space-y-4" aria-labelledby="published-heading">
          <div class="flex items-end justify-between gap-4 px-1">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.18em] text-[var(--session-muted)]">
                Ready
              </p>
              <h2 id="published-heading" class="mt-1 text-2xl font-semibold text-[var(--session-ink)]">
                Published workouts
              </h2>
            </div>
          </div>
          <div id="published-workouts" phx-update="stream" class="grid gap-4 sm:grid-cols-2">
            <p
              id="published-workouts-empty"
              class="hidden only:block rounded-3xl border border-dashed border-[var(--session-border)] px-6 py-10 text-center text-sm text-[var(--session-muted)]"
            >
              No published workouts are available.
            </p>
            <WorkoutLibraryComponents.published_workout
              :for={{dom_id, plan} <- @streams.published}
              id={dom_id}
              plan={plan}
              owned?={plan.user_id == @current_user.id}
              client_session_id={@start_client_session_id}
            />
          </div>
        </section>

        <section class="space-y-4" aria-labelledby="draft-heading">
          <div class="px-1">
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-[var(--session-muted)]">
              Private
            </p>
            <h2 id="draft-heading" class="mt-1 text-2xl font-semibold text-[var(--session-ink)]">
              Drafts
            </h2>
          </div>
          <div id="draft-workouts" phx-update="stream" class="grid gap-4 sm:grid-cols-2">
            <p
              id="draft-workouts-empty"
              class="hidden only:block rounded-3xl border border-dashed border-[var(--session-border)] px-6 py-10 text-center text-sm text-[var(--session-muted)]"
            >
              No drafts. Create one when you want another option.
            </p>
            <WorkoutLibraryComponents.draft_workout
              :for={{dom_id, draft} <- @streams.drafts}
              id={dom_id}
              plan={draft}
              form={Map.fetch!(@refine_forms, draft.id)}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp request_form(name), do: to_form(%{"request" => ""}, as: name)

  defp refine_forms(drafts) do
    Map.new(drafts, &{&1.id, request_form(:refinement)})
  end

  defp put_refine_form(socket, draft) do
    assign(
      socket,
      :refine_forms,
      Map.put(socket.assigns.refine_forms, draft.id, request_form(:refinement))
    )
  end

  defp drop_refine_form(socket, draft_id) do
    assign(socket, :refine_forms, Map.delete(socket.assigns.refine_forms, draft_id))
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _invalid -> {:error, :invalid_id}
    end
  end

  defp parse_id(_value), do: {:error, :invalid_id}
end
