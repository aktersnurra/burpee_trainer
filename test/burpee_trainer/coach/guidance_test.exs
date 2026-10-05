defmodule BurpeeTrainer.Coach.GuidanceTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach.{Guidance, Memory}

  test "store explicit guidance without provider traffic and limit user text" do
    user = user_fixture()
    assert {:ok, entry} = Guidance.add(user, "  Build toward 50 reps.  ")
    assert entry.text == "Build toward 50 reps."
    assert entry.kind == "pending"
    assert [%{id: id}] = Guidance.list(user)
    assert id == entry.id
    assert {:error, :invalid_text} = Guidance.add(user, "  \n  ")
    assert {:error, :invalid_text} = Guidance.add(user, String.duplicate("x", 1001))
  end

  test "original guidance and curated memory remain owned and removable" do
    owner = user_fixture()
    stranger = user_fixture()
    assert {:ok, entry} = Guidance.add(owner, "Prefer shorter sets")

    assert Enum.any?(
             Memory.global_context(owner).coach_guidance.pending,
             &(&1.text == entry.text)
           )

    assert Guidance.list(stranger) == []
    assert {:error, :not_found} = Guidance.remove(stranger, entry.id)

    answer = fn _messages, _opts ->
      {:ok, %{"kind" => "lasting", "summary" => "Prefers shorter sets"}}
    end

    assert {:ok, reviewed} = Guidance.review(entry.id, complete: answer)
    assert reviewed.kind == "lasting"
    assert reviewed.summary == "Prefers shorter sets"

    assert {:ok, ^reviewed} =
             Guidance.review(entry.id, complete: fn _, _ -> flunk("duplicate review") end)

    assert Enum.any?(
             Memory.global_context(owner).coach_guidance.lasting,
             &(&1.summary == reviewed.summary)
           )

    assert {:error, :not_found} = Guidance.update(stranger, entry.id, "Stranger's instruction")
    assert {:error, :invalid_text} = Guidance.update(owner, entry.id, "  ")
    assert {:error, :invalid_text} = Guidance.update(owner, entry.id, String.duplicate("x", 1001))
    assert {:ok, edited} = Guidance.update(owner, entry.id, "Prefer longer sets")
    assert edited.text == "Prefer longer sets"
    assert edited.kind == "pending"
    assert edited.summary == nil
    assert Memory.global_context(owner).coach_guidance.lasting == []
    assert [%{text: "Prefer longer sets"}] = Memory.global_context(owner).coach_guidance.pending

    assert Guidance.remove(owner, entry.id) == :ok
    assert Guidance.list(owner) == []
    assert Memory.global_context(owner).coach_guidance.lasting == []
  end

  test "saving unchanged guidance keeps its reading and spends no review" do
    user = user_fixture()
    {:ok, entry} = Guidance.add(user, "Build toward 50 reps")
    answer = fn _, _ -> {:ok, %{"kind" => "lasting", "summary" => "Wants 50 reps"}} end
    assert {:ok, reviewed} = Guidance.review(entry.id, complete: answer)

    assert {:ok, ^reviewed} = Guidance.update(user, entry.id, "  Build toward 50 reps ")
    assert {:ok, ^reviewed} = Guidance.review(entry.id, complete: fn _, _ -> flunk("paid") end)
    assert [%{kind: "lasting", summary: "Wants 50 reps"}] = Guidance.list(user)
  end

  test "busy coach background work never drops a requested review" do
    user = user_fixture()
    parent = self()

    blockers =
      for _ <- 1..3 do
        {:ok, pid} =
          Task.Supervisor.start_child(BurpeeTrainer.CoachMemoryTaskSupervisor, fn ->
            send(parent, {:blocking, self()})

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end
          end)

        assert_receive {:blocking, ^pid}
        pid
      end

    assert {:ok, entry} = Guidance.add(user, "Prefer shorter sets")
    assert {:ok, _pid} = Guidance.start_review(entry)
    Enum.each(blockers, &send(&1, :release))
  end

  test "temporary guidance is not promoted to lasting memory" do
    user = user_fixture()
    assert {:ok, entry} = Guidance.add(user, "Take it easy next time")
    answer = fn _, _ -> {:ok, %{"kind" => "temporary", "summary" => "Go easy next session"}} end
    assert {:ok, _} = Guidance.review(entry.id, complete: answer)
    context = Memory.global_context(user).coach_guidance
    assert context.lasting == []
    assert [%{summary: "Go easy next session"}] = context.temporary
  end

  test "a failed coach review does not discard pending guidance" do
    user = user_fixture()
    assert {:ok, entry} = Guidance.add(user, "Aim for consistency")

    assert {:error, :provider_unavailable} =
             Guidance.review(entry.id, complete: fn _, _ -> {:error, :provider_unavailable} end)

    assert [%{kind: "pending"}] = Guidance.list(user)
    assert Enum.any?(Memory.global_context(user).coach_guidance.pending, &(&1.text == entry.text))
  end
end
