defmodule BurpeeTrainer.Mcp.MemoryGoalToolsTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Goals, Mcp}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Memory, SummaryJob}

  defp call(scope, name, arguments \\ %{}) do
    {:reply, %{"result" => result}} =
      Mcp.handle(scope, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    if result["isError"],
      do: {:error, hd(result["content"])["text"]},
      else: {:ok, result["structuredContent"]}
  end

  setup do
    user = user_fixture()
    {:ok, user: user, scope: Scope.for_user(user)}
  end

  describe "memory" do
    test "entries are added, patched and removed by text, as the app's coach does",
         %{scope: scope} do
      Memory.subscribe(scope)

      {:ok, result} =
        call(scope, "update_memory", %{
          "target" => "user",
          "operations" => [
            %{"action" => "add", "content" => "Trains before work, around 6:30."},
            %{"action" => "add", "content" => "Left knee was sore in October."}
          ]
        })

      assert result["success"] and result["changed"]
      assert result["usage"] =~ "/1,375"
      assert_receive :coach_memory

      {:ok, %{"user" => %{"entries" => [early, _knee]}, "memory" => %{"entries" => []}}} =
        call(scope, "list_memory")

      assert early["text"] == "Trains before work, around 6:30."

      {:ok, result} =
        call(scope, "update_memory", %{
          "target" => "user",
          "operations" => [
            %{"action" => "patch", "old_text" => "6:30", "content" => "7:00"},
            %{"action" => "remove", "old_text" => "knee"}
          ]
        })

      assert result["entries"] == ["Trains before work, around 7:00."]
    end

    test "a refused batch is reported with the entries and changes nothing", %{scope: scope} do
      assert {:error, message} =
               call(scope, "update_memory", %{
                 "target" => "user",
                 "operations" => [
                   %{"action" => "add", "content" => "Trains mornings."},
                   %{"action" => "add", "content" => "Prefers six_count."}
                 ]
               })

      assert %{"success" => false, "error" => error, "current_entries" => []} =
               Jason.decode!(message)

      assert error =~ "internal id"
      assert Memory.list(scope) == []
    end

    test "another user's entries cannot be read or removed", %{scope: scope} do
      other = Scope.for_user(user_fixture())

      {:ok, _} =
        Memory.write(other, "user", [%{"action" => "add", "content" => "Someone else."}])

      {:ok, %{"user" => %{"entries" => []}}} = call(scope, "list_memory")

      assert {:error, _} =
               call(scope, "update_memory", %{
                 "target" => "user",
                 "operations" => [%{"action" => "remove", "old_text" => "Someone else."}]
               })

      assert [_] = Memory.list(other)
    end
  end

  describe "goals" do
    test "set_goal makes a goal active at once, replacing the type's old one",
         %{user: user, scope: scope} do
      old = goal_fixture(user, %{burpee_type: "six_count"})
      date = Date.to_iso8601(Date.add(Date.utc_today(), 56))

      {:ok, %{"goal" => goal}} =
        call(scope, "set_goal", %{"burpee_type" => "six_count", "reps" => 200, "date" => date})

      assert goal["status"] == "active"
      assert goal["reps"] == 200
      assert goal["duration_sec"] == 1200
      assert Goals.get_active_goal(scope, :six_count).id == goal["id"]
      assert BurpeeTrainer.Repo.reload(old).status == :abandoned

      assert BurpeeTrainer.Repo.exists?(
               from j in Oban.Job,
                 where: j.worker == ^inspect(SummaryJob) and j.args["user_id"] == ^user.id
             )

      {:ok, %{"goals" => goals}} = call(scope, "list_goals")
      assert Enum.map(goals, & &1["id"]) == [goal["id"]]
    end

    test "a goal the app would not accept is refused with the reason", %{scope: scope} do
      for args <- [
            %{"burpee_type" => "six_count", "reps" => 0, "date" => "2030-01-01"},
            %{"burpee_type" => "burpee", "reps" => 100, "date" => "2030-01-01"},
            %{"burpee_type" => "six_count", "reps" => 100, "date" => "soon"},
            %{
              "burpee_type" => "six_count",
              "reps" => 100,
              "date" => "2030-01-01",
              "duration_sec" => 1800
            }
          ] do
        assert {:error, _} = call(scope, "set_goal", args)
      end

      assert Goals.list(scope) == []
    end

    test "a proposed goal can be confirmed or dismissed", %{user: user, scope: scope} do
      proposed = goal_fixture(user, %{burpee_type: "navy_seal", status: "proposed"})
      other = goal_fixture(user, %{burpee_type: "six_count", status: "proposed"})

      {:ok, %{"goal" => %{"status" => "active"}}} =
        call(scope, "confirm_goal", %{"id" => proposed.id})

      {:ok, %{"goal" => %{"status" => "abandoned"}}} =
        call(scope, "dismiss_goal", %{"id" => other.id})

      assert {:error, _} = call(scope, "confirm_goal", %{"id" => other.id})
    end
  end
end
