defmodule BurpeeTrainer.Coach.Agent do
  @moduledoc "Bounded scoped coach loop; tool errors are visible to the model, not exceptions."
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Suggestions
  alias BurpeeTrainer.Coach.{Client, Tool, Tools, AgentPrompt}

  @tools %{
    planner: [
      Tools.History,
      Tools.Goals,
      Tools.Library,
      Tools.ProposeWorkout,
      Tools.SelectWorkout
    ],
    coach_page: [Tools.History, Tools.Goals, Tools.ProposeGoal]
  }
  @spec run(Scope.t(), :planner | :coach_page, String.t() | nil, keyword()) ::
          {:ok, %{reply: String.t(), suggestions: [String.t()]}} | {:error, term()}
  def run(%Scope{} = scope, surface, input, opts \\ []) when surface in [:planner, :coach_page] do
    tools = Map.fetch!(@tools, surface)

    run = %{
      run_id: Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0),
      surface: surface,
      slot: Keyword.get(opts, :slot),
      pending_selection: nil,
      proposals: 0,
      call_index: 0
    }

    if surface == :coach_page and
         (not is_binary(input) or String.length(input) > 1000 or byte_size(input) > 8000) do
      {:error, :invalid_input}
    else
      with {:ok, expected} <- original_selection(scope, run) do
        run = Map.put(run, :expected_selection, expected)

        messages =
          AgentPrompt.messages(
            scope,
            surface,
            input,
            run.slot,
            Keyword.get(opts, :history, [])
          )

        loop(scope, messages, tools, run, 0, opts)
      end
    end
  end

  defp loop(_, _, _, _, calls, _) when calls >= 6, do: {:error, :agent_budget_exhausted}

  defp loop(scope, messages, tools, run, calls, opts) do
    if byte_size(Jason.encode!(messages)) > 262_144 do
      {:error, :agent_budget_exhausted}
    else
      opts =
        opts
        |> Keyword.take([:config, :req, :budget])
        |> Keyword.merge(
          tools: Enum.map(tools, &Tool.definition/1),
          response_format:
            {"coach_reply",
             Tool.object(
               %{
                 "reply" => %{"type" => "string", "maxLength" => 600},
                 "suggestions" => Suggestions.schema()
               },
               ["reply"]
             )},
          ledger: %{
            scope: scope,
            purpose: if(run.surface == :planner, do: "plan_next", else: "coach_message"),
            run_id: run.run_id
          }
        )

      case Client.chat(messages, opts) do
        {:ok, %{tool_calls: [], content: %{"reply" => reply} = content}}
        when is_binary(reply) and map_size(content) <= 2 ->
          cond do
            Map.keys(content) -- ["reply", "suggestions"] != [] ->
              {:error, :invalid_provider_response}

            String.length(reply) > 600 ->
              {:error, :invalid_provider_response}

            true ->
              with {:ok, result} <- finalize(scope, run, reply),
                   do:
                     {:ok,
                      Map.put(result, :suggestions, Suggestions.clean(content["suggestions"]))}
          end

        {:ok, %{tool_calls: [_ | _] = calls_returned}} ->
          if run.proposals + Enum.count(calls_returned, &(&1.name == Tools.ProposeWorkout.name())) >
               3 do
            {:error, :agent_budget_exhausted}
          else
            {results, run} =
              Enum.map_reduce(calls_returned, run, fn call, run ->
                execute(scope, tools, call, run)
              end)

            assistant = %{
              role: "assistant",
              content: nil,
              tool_calls:
                Enum.map(calls_returned, fn c ->
                  %{
                    id: c.id,
                    type: "function",
                    function: %{name: c.name, arguments: Jason.encode!(c.arguments)}
                  }
                end)
            }

            loop(scope, messages ++ [assistant | results], tools, run, calls + 1, opts)
          end

        {:error, error} ->
          {:error, error}

        _ ->
          {:error, :invalid_provider_response}
      end
    end
  end

  defp original_selection(scope, %{surface: :planner, slot: slot}) when is_map(slot),
    do: BurpeeTrainer.Workouts.ensure_home_selection(scope, slot)

  defp original_selection(_, _), do: {:ok, nil}

  # No provider I/O occurs in the final selection transaction. Owner revisions win.
  # A staged proposal is persisted here, together with its selection, or not at all.
  defp finalize(scope, %{pending_selection: %{rationale: rationale} = pending} = run, reply) do
    with {:ok, _} <-
           BurpeeTrainer.Workouts.select_planned_workout(
             scope,
             run.expected_selection,
             planned_target(pending),
             rationale
           ) do
      {:ok, %{reply: reply}}
    end
  end

  defp finalize(_, _, reply), do: {:ok, %{reply: reply}}

  defp planned_target(%{plan_id: id}), do: {:plan, id}

  defp planned_target(%{definition: definition, approval_key: key}),
    do: {:proposal, definition, key}

  defp execute(scope, tools, call, run) do
    run = %{run | call_index: run.call_index + 1}

    {result, run} =
      case Enum.find(tools, &(&1.name() == call.name)) do
        nil ->
          {{:error, "unknown or unavailable tool"}, run}

        Tools.ProposeWorkout when run.proposals >= 3 ->
          {{:error, "workout proposal limit reached"}, run}

        module ->
          run =
            if module == Tools.ProposeWorkout,
              do: %{run | proposals: run.proposals + 1},
              else: run

          case module.call(scope, call.arguments, run) do
            {:ok, result, changes} -> {{:ok, result}, Map.merge(run, changes)}
            result -> {result, run}
          end
      end

    content =
      case result do
        {:ok, map} -> map
        {:error, reason} -> %{"error" => reason}
      end

    {%{role: "tool", tool_call_id: call.id, content: Jason.encode!(content)}, run}
  end
end
