defmodule BurpeeTrainerWeb.HomeWorkspace do
  @moduledoc "Workspace responsibility of the shared Home workspace; ordinary module."

  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainer.Coach.Catalog
  alias BurpeeTrainer.Workouts.Inspection
  alias BurpeeTrainerWeb.{HomeWorkoutRequest, HomeChooser, HomeAuthoring, HomeLive}

  def assign_workspace(socket) do
    socket =
      socket
      |> assign(
        home_selection: nil,
        expanded?: false,
        alternatives_open?: false,
        chooser_open?: false,
        swap_preview: nil,
        filters_open?: false,
        active_tab: :workouts,
        filters: Catalog.default_filters(socket.assigns.current_level),
        instruction: "",
        authoring_stage: :idle,
        workout_parameters: %HomeWorkoutRequest{},
        workout_form:
          to_form(HomeWorkoutRequest.changeset(%HomeWorkoutRequest{}, %{}), as: :home_workout),
        creation_key: nil,
        created_plan: nil,
        pending_request: nil,
        busy?: false,
        update_id: nil,
        local_error: nil,
        expanded_groups: MapSet.new(),
        inspection_rows: [],
        alternatives_empty?: true
      )
      |> HomeAuthoring.adjustment_form("")
      |> stream(:alternatives, [], dom_id: &"home-alternative-#{&1.id}")

    case socket.assigns.home_state do
      {:start, selected} ->
        show_selection(socket, selected, false)

      :choose ->
        HomeChooser.refresh_alternatives(socket)

      _ ->
        socket
    end
  end

  # Refresh an idle projection from the one genuine facts load. Unlike an
  # explicit choice, observation must not reset drafts, expansion or CAS tokens.
  def refresh_projection(
        %{
          assigns: %{
            home_state: {:start, selected},
            busy?: false,
            pending_request: nil,
            authoring_stage: :idle
          }
        } = socket
      ) do
    assign(socket,
      home_selection: selected,
      inspection_rows: Inspection.rows(selected.plan)
    )
  end

  def refresh_projection(socket), do: socket

  def show_selection(socket, selected, expanded?) do
    socket =
      if socket.assigns.home_facts.selection == selected,
        do: socket,
        else: HomeLive.assign_home(socket)

    socket
    |> assign(
      home_selection: selected,
      authoring_stage: :idle,
      swap_preview: nil,
      expanded?: expanded?,
      instruction: "",
      pending_request: nil,
      local_error: nil,
      expanded_groups: MapSet.new(),
      alternatives_open?: false,
      chooser_open?: false,
      inspection_rows: Inspection.rows(selected.plan),
      start_client_session_id: Ecto.UUID.generate()
    )
    |> HomeAuthoring.adjustment_form("")
    |> notify_adjustment_reset()
    |> HomeChooser.refresh_alternatives()
  end

  def notify_adjustment_reset(socket) do
    if connected?(socket), do: push_event(socket, "home_adjustment_reset", %{}), else: socket
  end
end
