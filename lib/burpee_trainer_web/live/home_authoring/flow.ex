defmodule BurpeeTrainerWeb.HomeAuthoring.Flow do
  @moduledoc """
  Pure: the authoring workflow of the Home workspace.

  `update/2` takes the model and a semantic event and returns the next model and the
  commands the LiveView adapter runs. Nothing here reads the database, calls the coach or
  touches the socket; the adapter does that and reports what happened as an event.

  Work in flight is identified by `update_id`. A result is applied only while it is the
  one in flight, so a late answer to a discarded or superseded request changes nothing.
  """

  @type stage :: :idle | :new | :editing | :review | :saved | :choosing

  @type command ::
          {:cancel_async, {:new_request, reference()}}
          | :refresh_alternatives

  @type t :: %__MODULE__{}

  @fields [
    authoring_stage: :idle,
    authoring_returned?: false,
    editing_source: nil,
    workout_parameters: nil,
    creation_key: nil,
    created_plan: nil,
    pending_request: nil,
    review_inspection_rows: [],
    instruction: "",
    busy?: false,
    update_id: nil,
    local_error: nil
  ]

  defstruct @fields

  @keys Keyword.keys(@fields)

  @spec from_assigns(map()) :: t()
  def from_assigns(assigns), do: struct!(__MODULE__, Map.take(assigns, @keys))

  @spec to_assigns(t()) :: keyword()
  def to_assigns(%__MODULE__{} = model), do: model |> Map.take(@keys) |> Map.to_list()

  @spec current?(t(), reference() | nil) :: boolean()
  def current?(%__MODULE__{update_id: id}, id) when not is_nil(id), do: true
  def current?(%__MODULE__{}, _id), do: false

  @spec update(t(), term()) :: {t(), [command()]}

  # Opening and leaving the creator

  def update(%__MODULE__{authoring_stage: :idle} = m, {:new_opened, params, key}) do
    {open(m, :new, params, key), []}
  end

  def update(%__MODULE__{authoring_stage: :idle} = m, {:edit_opened, source, params, key}) do
    {%{open(m, :editing, params, key) | editing_source: source, instruction: ""}, []}
  end

  def update(%__MODULE__{} = m, :aborted) do
    {discarded, commands} = discard(m)

    {%{
       discarded
       | authoring_stage: :idle,
         created_plan: nil,
         # Only New takes the workout away; Edit keeps it in view, so nothing returns.
         authoring_returned?: is_nil(m.editing_source)
     }, commands}
  end

  def update(%__MODULE__{} = m, :editing_resumed) do
    {discarded, commands} = discard(m)
    {%{discarded | authoring_stage: :editing}, commands}
  end

  def update(%__MODULE__{} = m, {:instruction_changed, text}) do
    {discarded, commands} = discard(m)
    {%{discarded | instruction: text}, commands}
  end

  def update(%__MODULE__{} = m, :preparation_discarded), do: discard(m)

  def update(%__MODULE__{authoring_stage: :saved} = m, :created_selected),
    do: {%{m | authoring_stage: :idle, created_plan: nil}, []}

  def update(%__MODULE__{} = m, :request_reopened),
    do: {%{m | pending_request: nil, local_error: nil}, []}

  # Work starting: a new request supersedes what was in flight.

  def update(%__MODULE__{} = m, {:review_started, id, text}) do
    {discarded, commands} = discard(m)
    {%{discarded | busy?: true, update_id: id, instruction: text}, commands}
  end

  def update(%__MODULE__{} = m, {:adjustment_started, id, text}),
    do: {%{m | busy?: true, update_id: id, instruction: text, local_error: nil}, []}

  def update(%__MODULE__{} = m, {:confirm_started, id}),
    do: {%{m | busy?: true, update_id: id, local_error: nil}, []}

  # Work finishing: applied only while it is the one in flight.

  def update(%__MODULE__{} = m, {:review_prepared, id, prepared, params, rows}) do
    settle(m, id, fn m ->
      {%{
         m
         | authoring_stage: :review,
           review_inspection_rows: rows,
           pending_request: prepared,
           workout_parameters: params
       }, []}
    end)
  end

  def update(%__MODULE__{} = m, {:review_failed, id, message}),
    do: settle(m, id, &{%{&1 | pending_request: nil, local_error: message}, []})

  def update(%__MODULE__{} = m, {:plan_saved, id, plan}) do
    settle(m, id, fn m ->
      {%{m | authoring_stage: :saved, pending_request: nil, created_plan: plan},
       [:refresh_alternatives]}
    end)
  end

  def update(%__MODULE__{} = m, {:plan_selected, id}) do
    settle(m, id, fn m ->
      {%{
         m
         | authoring_stage: :idle,
           pending_request: nil,
           created_plan: nil,
           editing_source: nil,
           authoring_returned?: true
       }, []}
    end)
  end

  def update(%__MODULE__{} = m, {:plan_failed, id, message}),
    do: settle(m, id, &{%{&1 | local_error: message}, []})

  def update(%__MODULE__{} = m, {:revision_prepared, id, prepared}),
    do: settle(m, id, &{%{&1 | pending_request: prepared, local_error: nil}, []})

  def update(%__MODULE__{} = m, {:revision_prepare_failed, id, message}),
    do: settle(m, id, &{%{&1 | pending_request: nil, local_error: message}, []})

  def update(%__MODULE__{} = m, {:revision_applied, id}), do: settle(m, id, &{&1, []})

  def update(%__MODULE__{} = m, {:revision_blocked, id, message}),
    do: settle(m, id, &{%{&1 | local_error: message}, []})

  def update(%__MODULE__{} = m, {:revision_failed, id, message}) do
    settle(m, id, fn m ->
      {%{m | pending_request: nil, local_error: message}, [:refresh_alternatives]}
    end)
  end

  def update(%__MODULE__{} = m, _event), do: {m, []}

  defp open(m, stage, params, key) do
    %{
      m
      | authoring_stage: stage,
        authoring_returned?: false,
        editing_source: nil,
        workout_parameters: params,
        creation_key: key,
        created_plan: nil,
        pending_request: nil,
        local_error: nil
    }
  end

  # Drops the preparation and cancels the request still running for it.
  defp discard(%__MODULE__{busy?: true, update_id: id} = m) when not is_nil(id) do
    {%{clear(m) | busy?: false, update_id: nil}, [{:cancel_async, {:new_request, id}}]}
  end

  defp discard(m), do: {%{clear(m) | busy?: false, update_id: nil}, []}

  defp clear(m), do: %{m | pending_request: nil, local_error: nil}

  defp settle(m, id, apply_result) do
    if current?(m, id) do
      apply_result.(%{m | busy?: false, update_id: nil})
    else
      {m, []}
    end
  end
end
