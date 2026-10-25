defmodule BurpeeTrainerWeb.HomeChooser do
  @moduledoc "Chooser responsibility of the shared Home workspace; ordinary module."

  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Catalog
  alias BurpeeTrainer.Workouts.CoachRecommendation
  alias BurpeeTrainerWeb.{HomeWorkspace, HomeLive}

  def handle_event("toggle_other", _, socket),
    do: {:noreply, assign(socket, alternatives_open?: not socket.assigns.alternatives_open?)}

  def handle_event("open_chooser", _, socket) do
    if socket.assigns.home_selection || socket.assigns.home_state == :choose,
      do:
        {:noreply,
         socket
         |> assign(chooser_open?: true, alternatives_open?: true)
         |> refresh_alternatives()},
      else: {:noreply, socket}
  end

  def handle_event("close_chooser", _, socket),
    do: {:noreply, assign(socket, chooser_open?: false)}

  def handle_event("toggle_filters", _, socket),
    do:
      {:noreply,
       assign(socket, filters_open?: not socket.assigns.filters_open?, alternatives_open?: true)}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["workouts", "videos"] do
    {:noreply,
     socket
     |> assign(active_tab: if(tab == "workouts", do: :workouts, else: :videos))
     |> refresh_alternatives()}
  end

  def handle_event("filter", %{"kind" => kind, "filter" => value}, socket)
      when kind in ["type", "level"] do
    {key, allowed} =
      if kind == "type",
        do: {:types, [:six_count, :navy_seal]},
        else: {:levels, BurpeeTrainer.Levels.all_levels()}

    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil ->
        {:noreply, socket}

      atom ->
        set = Map.fetch!(socket.assigns.filters, key)

        set =
          if MapSet.member?(set, atom), do: MapSet.delete(set, atom), else: MapSet.put(set, atom)

        {:noreply,
         socket
         |> assign(filters: Map.put(socket.assigns.filters, key, set))
         |> refresh_alternatives()}
    end
  end

  def handle_event("reset_filters", _, socket),
    do:
      {:noreply,
       socket
       |> assign(filters: Catalog.default_filters(socket.assigns.current_level))
       |> refresh_alternatives()}

  def handle_event("toggle_group", %{"id" => id}, socket) do
    rows =
      if socket.assigns.authoring_stage in [:review, :choosing],
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

  def handle_event("delete_workout", %{"id" => id}, socket) when is_binary(id) do
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
         alternatives_open?: true,
         expanded?: a.expanded?,
         filters: a.filters,
         filters_open?: a.filters_open?,
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

  def handle_event("preview_alternative", params, %{assigns: %{home_state: :choose}} = socket),
    do: handle_event("select_alternative", params, socket)

  def handle_event("preview_alternative", %{"id" => id, "kind" => kind}, socket) do
    with :idle <- socket.assigns.authoring_stage,
         {id, ""} <- Integer.parse(id),
         {:ok, source, rows} <- preview_source(socket.assigns.current_scope, kind, id) do
      {:noreply,
       assign(socket,
         authoring_stage: :choosing,
         swap_preview: %{kind: kind, source: source},
         review_inspection_rows: rows,
         chooser_open?: false,
         expanded?: true,
         expanded_groups: MapSet.new(),
         local_error: nil
       )}
    else
      _ -> {:noreply, assign(socket, local_error: "That workout is no longer available.")}
    end
  end

  def handle_event(
        "use_alternative",
        _,
        %{assigns: %{authoring_stage: :choosing, swap_preview: preview}} = socket
      ) do
    handle_event(
      "select_alternative",
      %{"id" => to_string(preview.source.id), "kind" => preview.kind},
      socket
    )
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

  def refresh_alternatives(%{assigns: %{slot: nil}} = socket), do: socket

  def refresh_alternatives(%{assigns: %{home_selection: nil, home_state: :choose}} = socket) do
    a = socket.assigns

    items =
      case a.active_tab do
        :workouts ->
          Workouts.list_library(a.current_scope)
          |> Catalog.order_plans([], a.slot, a.current_level)
          |> Catalog.filter(a.filters, &Catalog.plan_level/1)
          |> Enum.map(&alternative_item/1)

        :videos ->
          BurpeeTrainer.Videos.list_home_videos()
          |> Catalog.order_videos()
          |> Catalog.filter(a.filters, &Catalog.video_level/1)
          |> Enum.map(&alternative_item/1)
      end

    socket
    |> assign(alternatives_empty?: items == [])
    |> stream(:alternatives, items, reset: true)
  end

  def refresh_alternatives(socket) do
    a = socket.assigns

    r =
      Repo.get_by!(CoachRecommendation,
        id: a.home_selection.recommendation_id,
        user_id: a.current_scope.user.id
      )

    items =
      case a.active_tab do
        :workouts ->
          plans =
            Catalog.order_plans(
              Workouts.list_library(a.current_scope),
              Map.get(r.ranked_plan_ids, "ids", []),
              a.slot,
              a.current_level
            )

          plans =
            case Workouts.get_draft(a.current_scope, r.pending_draft_id) do
              {:ok, pending} -> [pending | plans]
              _ -> plans
            end

          plans
          |> Catalog.filter(a.filters, &Catalog.plan_level/1)
          |> Enum.map(
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
          BurpeeTrainer.Videos.list_home_videos()
          |> Catalog.order_videos()
          |> Catalog.filter(a.filters, &Catalog.video_level/1)
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

    socket
    |> assign(alternatives_empty?: items == [])
    |> stream(:alternatives, items, reset: true)
  end

  defp preview_source(scope, "plan", id) do
    with {:ok, plan} <- Workouts.get_library_plan(scope, id),
         :ok <- Workouts.verify_plan_content(plan) do
      {:ok, plan, BurpeeTrainer.Workouts.Inspection.rows(plan)}
    end
  end

  defp preview_source(_scope, "video", id) do
    case Enum.find(BurpeeTrainer.Videos.list_home_videos(), &(&1.id == id)) do
      nil -> {:error, :unavailable}
      video -> {:ok, video, []}
    end
  end

  defp preview_source(_, _, _), do: {:error, :unavailable}

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
