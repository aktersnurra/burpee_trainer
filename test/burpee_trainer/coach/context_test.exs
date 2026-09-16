defmodule BurpeeTrainer.Coach.ContextTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Context

  test "failed published workspace is found after reload" do
    user = user_fixture()
    source = plan_fixture(user)
    {:ok, a} = Context.ensure_session(user, source, "home:10:1")
    attempt = Ecto.UUID.generate()
    {:ok, _} = Context.append(user, a.id, attempt, :instruction, %{"text" => "Less rest"})

    {:ok, _} =
      Context.append(user, a.id, attempt, :outcome, %{
        "status" => "failed",
        "code" => "provider_timeout"
      })

    {:ok, b} = Context.ensure_session(user, Repo.reload!(source), "home:10:1")
    assert b.id == a.id
    {:ok, entries} = Context.entries(user, b.id)
    assert Enum.any?(entries, &(&1.payload["text"] == "Less rest"))
    {:ok, independent} = Context.ensure_session(user, source, "home:10:2")
    refute independent.id == a.id
    assert Repo.reload!(source).design_session_id == nil
  end

  test "shared source never copies request text or the author's private log" do
    owner = user_fixture()
    source = plan_fixture(owner, %{request_text: "private-author-request"})
    {:ok, private} = Context.ensure_session(owner, source, "creator:private")

    {:ok, _} =
      Context.append(owner, private.id, Ecto.UUID.generate(), :instruction, %{
        "text" => "private-author-instruction"
      })

    # Assemble the shared fixture before publication; never mutate an immutable source.
    fields = [
      :name,
      :request_text,
      :definition_json,
      :program_json,
      :content_hash,
      :burpee_type,
      :target_reps,
      :target_duration_sec
    ]

    shared =
      %BurpeeTrainer.Workouts.WorkoutPlan{
        user_id: nil,
        origin: :built_in,
        state: :draft,
        design_session_id: private.id
      }
      |> BurpeeTrainer.Workouts.WorkoutPlan.new_draft_changeset(Map.take(source, fields))
      |> Repo.insert!()
      |> BurpeeTrainer.Workouts.WorkoutPlan.publish_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

    viewer = user_fixture()
    {:ok, session} = Context.ensure_session(viewer, shared, "home:20:1")
    {:ok, entries} = Context.entries(viewer, session.id)
    encoded = Jason.encode!(Enum.map(entries, & &1.payload))
    refute encoded =~ "private-author-request"
    refute encoded =~ "private-author-instruction"
    baseline = Enum.find(entries, &(&1.kind == :baseline)).payload
    refute Map.has_key?(baseline, "request_text")
    refute Map.has_key?(baseline, "prior_owned_entries")
    assert {:error, _} = Context.entries(viewer, private.id)
  end

  test "each provider request names its own active concurrent attempt" do
    user = user_fixture()
    source = plan_fixture(user)
    {:ok, s} = Context.ensure_session(user, source, "home:30:1")
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    {:ok, _} = Context.append(user, s.id, a, :instruction, %{"text" => "Six-counts"})
    {:ok, _} = Context.append(user, s.id, b, :instruction, %{"text" => "Navy SEALs"})
    {:ok, _} = Context.append(user, s.id, b, :proposal, %{"invalid_rest_free_plan" => true})
    {:ok, _} = Context.append(user, s.id, b, :outcome, %{"status" => "failed"})
    {:ok, [_, _, message]} = Context.messages(user, s.id, source, a, "Contract")
    body = Jason.decode!(message.content)
    assert body["active_attempt"]["id"] == a
    assert body["active_attempt"]["instruction"] == "Six-counts"
    assert body["current_definition"] == source.definition_json

    assert Enum.map(body["entries"], & &1["kind"]) == [
             "initial_context",
             "baseline",
             "instruction"
           ]

    refute message.content =~ "invalid_rest_free_plan"
    assert length(elem(Context.entries(user, s.id), 1)) == 6
  end

  test "automatic recommendation retries retain their log without overflowing provider context" do
    user = user_fixture()
    {:ok, session} = Context.ensure_session(user, nil, "recommendation:123:1")

    for _ <- 1..70 do
      attempt = Ecto.UUID.generate()

      {:ok, _} =
        Context.append(user, session.id, attempt, :instruction, %{
          "text" => "Choose the next workout for this slot.",
          "request_messages" => [%{role: "user", content: String.duplicate("x", 5_000)}]
        })

      {:ok, _} =
        Context.append(user, session.id, attempt, :outcome, %{
          "status" => "failed",
          "code" => "provider_unavailable"
        })
    end

    active = Ecto.UUID.generate()

    {:ok, _} =
      Context.append(user, session.id, active, :instruction, %{
        "text" => "Choose the next workout for this slot.",
        "request_messages" => [%{role: "user", content: "current slot"}]
      })

    assert {:ok, [_, _, message]} =
             Context.messages(user, session.id, nil, active, "Coach recommendation")

    body = Jason.decode!(message.content)

    assert Enum.map(body["entries"], & &1["kind"]) == [
             "initial_context",
             "baseline",
             "instruction"
           ]

    assert List.last(body["entries"])["attempt_id"] == active
    assert length(elem(Context.entries(user, session.id), 1)) == 143
  end

  test "concurrent initializers produce one context and one initial baseline" do
    user = user_fixture()
    source = plan_fixture(user)
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.InitializerTasks})

    tasks =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Context.ensure_session(user, source, "home:40:1")
          end
        end)
      end

    for task <- tasks do
      assert_receive {:ready, pid}
      assert pid in Enum.map(tasks, & &1.pid)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, task.pid)
    end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await/1)
    assert [{:ok, a}, {:ok, b}] = results
    assert a.id == b.id
    {:ok, entries} = Context.entries(user, a.id)
    assert Enum.count(entries, &(&1.kind == :initial_context)) == 1
    assert Enum.count(entries, &(&1.kind == :baseline)) == 1
  end

  test "workspace provenance and all entry APIs enforce ownership" do
    user = user_fixture()
    other = user_fixture()
    source = plan_fixture(user)
    {:ok, s} = Context.ensure_session(user, source, "identity")
    assert {:error, _} = Context.ensure_session(user, nil, "identity")
    assert {:error, _} = Context.ensure_session(other, source, "foreign")
    assert {:error, _} = Context.append(other, s.id, Ecto.UUID.generate(), :instruction, %{})
    assert {:error, _} = Context.check_source(other, s.id, source)
    assert {:error, _} = Context.messages(other, s.id, source, Ecto.UUID.generate(), "prompt")
    assert {:error, _} = Context.check_source(user, "invalid-id", source)
    assert {:error, _} = Context.check_home_workspace(user, s.id, %{})

    assert {:error, _} =
             Context.check_home_workspace(user, s.id, %{
               plan: source,
               recommendation_id: 1,
               home_revision: 1
             })
  end

  test "Home revision keys bind a workspace and stale sources fail safely" do
    user = user_fixture()
    source = plan_fixture(user)
    expected = %{plan: source, recommendation_id: 2, home_revision: 3}
    {:ok, session} = Context.ensure_session(user, source, Context.home_key(expected))
    assert :ok = Context.check_home_workspace(user, session.id, expected)

    assert {:error, %{code: :design_workspace_changed}} =
             Context.check_home_workspace(user, session.id, %{expected | home_revision: 4})

    stale = %{source | content_hash: "stale"}
    assert {:error, %{code: :source_unavailable}} = Context.ensure_session(user, stale, "stale")
    assert {:error, %{code: :source_unavailable}} = Context.check_source(user, session.id, stale)
  end

  test "draft continuity, immutable owned import and deletion preserve the log" do
    user = user_fixture()
    draft = workout_plan_draft_fixture(user)
    {:ok, original} = Context.ensure_session(user, draft, "ignored")
    assert original.workspace_key == "draft:#{draft.id}"
    draft = draft |> Ecto.Changeset.change(design_session_id: original.id) |> Repo.update!()
    {:ok, continued} = Context.ensure_session(user, draft, "different")
    assert continued.id == original.id
    attempt = Ecto.UUID.generate()

    {:ok, _} =
      Context.append(user, original.id, attempt, :instruction, %{"text" => "owned history"})

    {:ok, published} = Workouts.publish_draft(user, draft.id)
    {:ok, imported} = Context.ensure_session(user, published, "independent")
    refute imported.id == original.id
    {:ok, before_entries} = Context.entries(user, imported.id)
    baseline = Enum.find(before_entries, &(&1.kind == :baseline))

    assert Enum.any?(
             baseline.payload["prior_owned_entries"],
             &(&1["payload"]["text"] == "owned history")
           )

    {:ok, _} =
      Context.append(user, original.id, Ecto.UUID.generate(), :instruction, %{"text" => "later"})

    assert {:ok, ^before_entries} = Context.entries(user, imported.id)

    active = Ecto.UUID.generate()
    {:ok, _} = Context.append(user, imported.id, active, :instruction, %{"text" => "Refine"})

    assert {:ok, [_, _, message]} =
             Context.messages(user, imported.id, published, active, "Contract")

    request = Jason.decode!(message.content)
    projected_baseline = Enum.find(request["entries"], &(&1["kind"] == "baseline"))
    refute Map.has_key?(projected_baseline["payload"], "prior_owned_entries")
    assert projected_baseline["payload"]["definition"] == published.definition_json
    refute message.content =~ "owned history"

    disposable = workout_plan_draft_fixture(user)
    {:ok, retained} = Context.ensure_session(user, disposable, "unused")
    Repo.delete!(disposable)
    assert {:ok, [_, _]} = Context.entries(user, retained.id)
  end

  test "append is insert-only, ordered and rejects malformed or duplicate entries" do
    user = user_fixture()
    {:ok, s} = Context.ensure_session(user, nil, "creator")
    attempt = Ecto.UUID.generate()
    {:ok, entry} = Context.append(user, s.id, attempt, :instruction, %{"text" => "first"})

    assert {:error, _} =
             Context.append(user, s.id, attempt, :instruction, %{"text" => "replacement"})

    assert {:error, _} = Context.append(user, s.id, "bad", :instruction, %{})
    assert {:error, _} = Context.append(user, s.id, attempt, :unknown, %{})

    assert_raise Exqlite.Error, ~r/design_entries_append_only/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE workout_design_entries SET payload = '{}' WHERE id = ?",
        [entry.id]
      )
    end

    {:ok, entries} = Context.entries(user, s.id)
    assert Enum.map(entries, & &1.id) == Enum.sort(Enum.map(entries, & &1.id))
    assert List.last(entries).payload == %{"text" => "first"}

    assert {:error, %{code: :design_attempt_not_found}} =
             Context.messages(user, s.id, nil, Ecto.UUID.generate(), "prompt")
  end

  test "persisted global context is owned while historical overflow stays out of requests" do
    alias BurpeeTrainer.Coach.{Memory, Setting, WorkoutMemory}
    user = user_fixture()
    other = user_fixture()
    Repo.insert!(%Setting{user_id: user.id, settings: %{"preference" => "persisted"}})
    Repo.insert!(%Setting{user_id: other.id, settings: %{"private" => "other"}})

    Repo.insert!(%WorkoutMemory{
      user_id: user.id,
      workout_plan_id: 123,
      facts: %{"reps" => 30},
      workout_reason: %{}
    })

    assert %{
             settings: %{"preference" => "persisted"},
             workout_memories: [%{workout_plan_id: 123}]
           } = Memory.global_context(user)

    {:ok, s} = Context.ensure_session(user, nil, "creator")
    {:ok, entries} = Context.entries(user, s.id)
    assert hd(entries).payload["global_context"]["settings"] == %{"preference" => "persisted"}
    attempt = Ecto.UUID.generate()
    {:ok, _} = Context.append(user, s.id, attempt, :instruction, %{"text" => "active"})

    {:ok, _} =
      Context.append(user, s.id, attempt, :proposal, %{"large" => String.duplicate("x", 262_145)})

    assert {:ok, [_, _, message]} = Context.messages(user, s.id, nil, attempt, "prompt")
    refute message.content =~ String.duplicate("x", 100)
    assert {:ok, [_, _, _, _]} = Context.entries(user, s.id)

    oversized_active = Ecto.UUID.generate()

    {:ok, _} =
      Context.append(user, s.id, oversized_active, :instruction, %{
        "text" => String.duplicate("x", 262_145)
      })

    assert {:error, %{code: :authoring_context_too_large}} =
             Context.messages(user, s.id, nil, oversized_active, "prompt")
  end

  test "accumulated finalized-workout memories stay bounded in authoring requests" do
    alias BurpeeTrainer.Coach.{Memory, WorkoutMemory}
    user = user_fixture()
    instruction = String.duplicate("i", 500)
    rationale = String.duplicate("r", 400)

    for plan_id <- 1..400 do
      Repo.insert!(%WorkoutMemory{
        user_id: user.id,
        workout_plan_id: plan_id,
        facts: %{"reps" => 100, "duration_sec" => 1200},
        workout_reason: %{"rationale" => rationale, "accepted_instructions" => [instruction]}
      })
    end

    memories = Memory.global_context(user).workout_memories
    assert length(memories) < 400
    assert List.last(memories).workout_plan_id == 400

    assert Enum.map(memories, & &1.workout_plan_id) ==
             Enum.sort(Enum.map(memories, & &1.workout_plan_id))

    {:ok, s} = Context.ensure_session(user, nil, "creator")
    attempt = Ecto.UUID.generate()
    {:ok, _} = Context.append(user, s.id, attempt, :instruction, %{"text" => "active"})
    assert {:ok, _messages} = Context.messages(user, s.id, nil, attempt, "prompt")
  end
end
