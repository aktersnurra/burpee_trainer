defmodule BurpeeTrainer.Mcp do
  @moduledoc """
  The MCP server Claude coaches through: JSON-RPC over stateless Streamable HTTP, one
  request per POST, JSON replies only. Tools are `Coach.Tool` modules, the same contract
  the in-app coach uses, so each tool's own clauses refuse invalid arguments before any
  effect. Every call runs as the signed-in user's scope.
  See docs/specs/2026-10-16-mcp-design.md.
  """

  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.{CoachPrompt, Tools, WorkoutFormat}

  @protocol_versions ~w[2025-06-18 2025-03-26 2024-11-05]

  @tools [
    Tools.CoachContext,
    Tools.Week,
    Tools.Progress,
    Tools.QueryHistory,
    Tools.HistoryStats,
    Tools.ListMemory,
    Tools.UpdateMemory,
    Tools.ListGoals,
    Tools.SetGoal,
    Tools.ConfirmGoal,
    Tools.DismissGoal,
    Tools.ListWorkouts,
    Tools.GetWorkout,
    Tools.CreateWorkout,
    Tools.EditWorkout,
    Tools.ArchiveWorkout
  ]

  def tools, do: @tools

  def latest_protocol_version, do: hd(@protocol_versions)

  @spec handle(Scope.t(), term(), [module()]) :: {:reply, map()} | :accepted
  def handle(scope, request, tools \\ tools())

  def handle(_scope, %{"jsonrpc" => "2.0", "method" => "notifications/" <> _} = request, _tools)
      when not is_map_key(request, "id"),
      do: :accepted

  def handle(
        %Scope{} = scope,
        %{"jsonrpc" => "2.0", "id" => id, "method" => method} = request,
        tools
      )
      when is_binary(method) do
    case dispatch(scope, method, Map.get(request, "params") || %{}, tools) do
      {:ok, result} -> {:reply, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
      {:error, code, message} -> error(id, code, message)
    end
  end

  def handle(_scope, request, _tools),
    do: error(if(is_map(request), do: Map.get(request, "id")), -32600, "Invalid Request")

  defp dispatch(_scope, "initialize", params, _tools) do
    requested = params["protocolVersion"]

    {:ok,
     %{
       "protocolVersion" =>
         if(requested in @protocol_versions, do: requested, else: latest_protocol_version()),
       "capabilities" => %{
         "tools" => %{"listChanged" => false},
         "prompts" => %{"listChanged" => false},
         "resources" => %{"listChanged" => false}
       },
       "serverInfo" => %{"name" => "burpee-trainer", "version" => version()}
     }}
  end

  defp dispatch(_scope, "ping", _params, _tools), do: {:ok, %{}}

  defp dispatch(_scope, "tools/list", _params, tools) do
    {:ok,
     %{
       "tools" =>
         Enum.map(tools, fn module ->
           %{name: name, description: description, schema: schema} = Tool.definition(module)
           %{"name" => name, "description" => description, "inputSchema" => schema}
         end)
     }}
  end

  defp dispatch(scope, "tools/call", %{"name" => name} = params, tools) when is_binary(name) do
    case Enum.find(tools, &(&1.name() == name)) do
      nil -> {:error, -32602, "Unknown tool: #{name}"}
      module -> {:ok, tool_result(module.call(scope, Map.get(params, "arguments") || %{}, %{}))}
    end
  end

  defp dispatch(_scope, "tools/call", _params, _tools),
    do: {:error, -32602, "tools/call needs a tool name"}

  defp dispatch(_scope, "prompts/list", _params, _tools),
    do:
      {:ok,
       %{
         "prompts" => [
           %{"name" => CoachPrompt.name(), "description" => CoachPrompt.description()}
         ]
       }}

  defp dispatch(_scope, "prompts/get", %{"name" => "coach"}, _tools),
    do:
      {:ok,
       %{
         "description" => CoachPrompt.description(),
         "messages" => [
           %{"role" => "user", "content" => %{"type" => "text", "text" => CoachPrompt.text()}}
         ]
       }}

  defp dispatch(_scope, "prompts/get", _params, _tools), do: {:error, -32602, "Unknown prompt"}

  defp dispatch(_scope, "resources/list", _params, _tools),
    do:
      {:ok,
       %{
         "resources" => [
           %{
             "uri" => WorkoutFormat.uri(),
             "name" => "workout-format",
             "title" => "How a workout is described",
             "mimeType" => "text/markdown"
           }
         ]
       }}

  defp dispatch(_scope, "resources/read", %{"uri" => uri}, _tools) when is_binary(uri) do
    if uri == WorkoutFormat.uri(),
      do:
        {:ok,
         %{
           "contents" => [
             %{"uri" => uri, "mimeType" => "text/markdown", "text" => WorkoutFormat.text()}
           ]
         }},
      else: {:error, -32602, "Unknown resource: #{uri}"}
  end

  defp dispatch(_scope, "resources/read", _params, _tools),
    do: {:error, -32602, "resources/read needs a uri"}

  defp dispatch(_scope, method, _params, _tools),
    do: {:error, -32601, "Method not found: #{method}"}

  defp tool_result({:ok, result, _run_changes}), do: tool_result({:ok, result})

  defp tool_result({:ok, result}) when is_map(result),
    do: %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
      "structuredContent" => result,
      "isError" => false
    }

  defp tool_result({:error, message}) when is_binary(message),
    do: %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}

  defp error(id, code, message),
    do:
      {:reply,
       %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}}

  defp version, do: Application.spec(:burpee_trainer, :vsn) |> to_string()
end
