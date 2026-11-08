defmodule BurpeeTrainerWeb.HomeChooser do
  @moduledoc "Chooser responsibility of the shared Home workspace; ordinary module."

  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Catalog
  alias BurpeeTrainer.Workouts.CoachRecommendation
  alias BurpeeTrainerWeb.{HomeWorkspace, HomeLive}

  def handle_event("open_chooser", _, socket) do
    if socket.assigns.home_selection || socket.assigns.home_state == :choose,
      do:
        {:noreply,
         socket
         |> assign(chooser_open?: true, delete_armed_id: nil)
         |> refresh_alternatives()},
      else: {:noreply, socket}
  end

  def handle_event("close_chooser", _, socket),
    do: {:noreply, assign(socket, chooser_open?: false, delete_armed_id: nil)}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["workouts", "videos"] do
    {:noreply,
     socket
     |> assign(
       active_tab: if(tab == "workouts", do: :workouts, else: :videos),
       delete_armed_id: nil
     )
     |> refresh_alternatives()}
  end

  def handle_event("toggle_filters", _, socket),
    do: {:noreply, assign(socket, filters_open?: not socket.assigns.filters_open?)}

  # A type or level pill turns its filter on or off; the list follows at once.
  def handle_event("filter", %{"kind" => kind, "filter" => value}, socket)
      when kind in ["type", "level"] and is_binary(value) do
    {key, allowed} =
      if kind == "type",
        do: {:types, [:six_count, :navy_seal]},
        else: {:levels, BurpeeTrainer.Levels.all_levels()}

    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil ->
        {:noreply, socket}

      choice ->
        set = Map.fetch!(socket.assigns.filters, key)

        set =
          if MapSet.member?(set, choice),
            do: MapSet.delete(set, choice),
            else: MapSet.put(set, choice)

        {:noreply,
         socket
         |> assign(filters: Map.put(socket.assigns.filters, key, set), delete_armed_id: nil)
         |> refresh_alternatives()}
    end
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("reset_filters", _, socket),
    do:
      {:noreply,
       socket
       |> assign(
         filters: Catalog.default_filters(socket.assigns.current_level),
         delete_armed_id: nil
       )
       |> refresh_alternatives()}

  def handle_event("toggle_group", %{"id" => id}, socket) do
    rows =
      if socket.assigns.authoring_stage == :review,
        do: socket.assigns.review_inspection_rows,
        else: socket.assigns.inspection_rows

    if Enum.any?(rows, &(&1.id == id and &1.count > 1)) do
      set = socket.assigns.expanded_groups
      set = if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
      {:noreply, assign(socket, expanded_groups: set)}
    else
      {:noreply, socket}
    end
  end

  # The first tap on a workout's trash arms it, in place; the second deletes it.
  def handle_event("delete_workout", %{"id" => raw} = params, socket) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} when id != socket.assigns.delete_armed_id ->
        {:noreply, socket |> assign(delete_armed_id: id) |> refresh_alternatives()}

      _ ->
        delete_armed_workout(params, socket)
    end
  end

  def handle_event("select_alternative", %{"id" => id, "kind" => kind}, socket)
      when is_binary(id) do
    with false <- socket.assigns.busy?,
         nil <- socket.assigns.pending_request,
         true <- socket.assigns.home_state != :choose or socket.assigns.authoring_stage == :idle,
         {id, ""} <- Integer.parse(id) do
      a = socket.assigns

      case kind do
        "plan" ->
          result =
            cond do
              a.home_state == :choose and is_nil(a.home_selection) ->
                Workouts.recover_home_workout_selection(a.current_scope, a.slot, id)

              true ->
                Workouts.select_home_workout(a.current_scope, a.home_selection, id)
            end

          case result do
            {:ok, selected} -> {:noreply, HomeWorkspace.show_selection(socket, selected, true)}
            _ -> {:noreply, assign(socket, local_error: "That workout is no longer available.")}
          end

        "video" ->
          result =
            cond do
              a.home_state == :choose and is_nil(a.home_selection) ->
                Workouts.start_recovery_home_video(
                  a.current_scope,
                  a.slot,
                  id,
                  a.start_client_session_id
                )

              true ->
                Workouts.start_home_video(
                  a.current_scope,
                  a.home_selection,
                  id,
                  a.start_client_session_id
                )
            end

          HomeLive.start_result(socket, result)

        _ ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp delete_armed_workout(%{"id" => id}, socket) do
    with false <- socket.assigns.busy?,
         nil <- socket.assigns.pending_request,
         :idle <- socket.assigns.authoring_stage,
         {id, ""} <- Integer.parse(id),
         {:ok, _archived} <- Workouts.archive_plan(socket.assigns.current_scope, id) do
      a = socket.assigns

      {:noreply,
       socket
       |> HomeLive.assign_home()
       |> HomeWorkspace.refresh_projection()
       |> assign(
         chooser_open?: true,
         delete_armed_id: nil,
         expanded?: a.expanded?,
         active_tab: a.active_tab
       )
       |> refresh_alternatives()}
    else
      _ ->
        socket =
          put_flash(
            socket,
            :error,
            "That workout could not be deleted. Your history is unchanged."
          )

        a = socket.assigns

        socket =
          if a.live_action == :home and a.chooser_open? and not a.busy? and
               is_nil(a.pending_request) and a.authoring_stage == :idle do
            push_event(socket, "home_chooser_rejected", %{})
          else
            socket
          end

        {:noreply, socket}
    end
  end

  def refresh_alternatives(%{assigns: %{slot: nil}} = socket), do: socket

  def refresh_alternatives(%{assigns: %{home_selection: nil, home_state: :choose}} = socket) do
    a = socket.assigns
    source = source(a)

    items =
      case a.active_tab do
        :workouts ->
          source
          |> Catalog.filter(a.filters, &Catalog.plan_level/1)
          |> Catalog.order_plans([], a.slot, a.current_level)
          |> Enum.map(&alternative_item/1)

        :videos ->
          source
          |> Catalog.filter(a.filters, &Catalog.video_level/1)
          |> Catalog.order_videos(a.current_level)
          |> Enum.map(&alternative_item/1)
      end

    put_alternatives(socket, items, source != [])
  end

  def refresh_alternatives(socket) do
    a = socket.assigns

    r =
      Repo.get_by!(CoachRecommendation,
        id: a.home_selection.recommendation_id,
        user_id: a.current_scope.user.id
      )

    source = source(a)

    items =
      case a.active_tab do
        :workouts ->
          plans =
            Catalog.order_plans(
              Catalog.filter(source, a.filters, &Catalog.plan_level/1),
              Map.get(r.ranked_plan_ids, "ids", []),
              a.slot,
              a.current_level
            )

          Enum.map(
            plans,
            &%{
              id: "plan-#{&1.id}",
              source_id: &1.id,
              kind: :plan,
              name: &1.name,
              owned?: &1.user_id == a.current_scope.user.id and &1.state == :published,
              duration_sec: &1.target_duration_sec,
              reps: &1.target_reps
            }
          )

        :videos ->
          source
          |> Catalog.filter(a.filters, &Catalog.video_level/1)
          |> Catalog.order_videos(a.current_level)
          |> Enum.map(
            &%{
              id: "video-#{&1.id}",
              source_id: &1.id,
              kind: :video,
              name: &1.name,
              duration_sec: &1.duration_sec,
              reps: &1.burpee_count
            }
          )
      end

    put_alternatives(socket, items, source != [])
  end

  # The tab's whole list, before the filters.
  defp source(%{active_tab: :workouts} = a), do: Workouts.list_library(a.current_scope)
  defp source(%{active_tab: :videos}), do: BurpeeTrainer.Videos.list_home_videos()

  # `any?`: whether the tab has anything before the filters, so an empty list can say which.
  defp put_alternatives(socket, items, any?) do
    armed = socket.assigns.delete_armed_id
    items = Enum.map(items, &Map.put(&1, :armed?, &1.kind == :plan and &1.source_id == armed))

    socket
    |> assign(alternatives_empty?: items == [], alternatives_filtered_out?: items == [] and any?)
    |> stream(:alternatives, items, reset: true)
  end

  defp alternative_item(%BurpeeTrainer.Workouts.WorkoutPlan{} = plan) do
    %{
      id: "plan-#{plan.id}",
      source_id: plan.id,
      kind: :plan,
      name: plan.name,
      owned?: not is_nil(plan.user_id) and plan.state == :published,
      duration_sec: plan.target_duration_sec,
      reps: plan.target_reps
    }
  end

  defp alternative_item(%BurpeeTrainer.Workouts.WorkoutVideo{} = video) do
    %{
      id: "video-#{video.id}",
      source_id: video.id,
      kind: :video,
      name: video.name,
      duration_sec: video.duration_sec,
      reps: video.burpee_count
    }
  end
end
