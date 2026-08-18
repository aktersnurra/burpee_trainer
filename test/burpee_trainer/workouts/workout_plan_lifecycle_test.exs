defmodule BurpeeTrainer.Workouts.WorkoutPlanLifecycleTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Error, WorkoutPlan}

  describe "library and draft visibility" do
    test "library includes owned published plans and shared built-ins only" do
      user = user_fixture()
      other_user = user_fixture()
      owned = published_plan_fixture(user, definition("Owned"))
      _draft = draft_fixture(user, definition("Draft"))
      _foreign = published_plan_fixture(other_user, definition("Foreign"))

      library = Workouts.list_library(user)

      assert Enum.any?(library, &(&1.id == owned.id))
      assert Enum.any?(library, &(&1.origin == :built_in and is_nil(&1.user_id)))
      refute Enum.any?(library, &(&1.name in ["Draft", "Foreign"]))
    end

    test "draft lookup distinguishes missing and foreign drafts" do
      owner = user_fixture()
      other_user = user_fixture()
      draft = draft_fixture(owner, definition("Owned draft"))

      assert Enum.map(Workouts.list_drafts(owner), & &1.id) == [draft.id]
      assert {:ok, %WorkoutPlan{id: id}} = Workouts.get_draft(owner, draft.id)
      assert id == draft.id

      assert {:error, %Error{code: :draft_not_owned, context: %{draft_id: draft_id}}} =
               Workouts.get_draft(other_user, draft.id)

      assert draft_id == draft.id

      assert {:error, %Error{code: :draft_not_found}} =
               Workouts.get_draft(owner, 2_147_483_647)

      published = published_plan_fixture(owner, definition("Published is not a draft"))

      assert {:error, %Error{code: :draft_required}} =
               Workouts.get_draft(owner, published.id)
    end
  end

  describe "draft creation and replacement" do
    test "creation derives every protected field after canonical validation and compilation" do
      user = user_fixture()

      attrs = %{
        "definition" => definition("Protected"),
        "request_text" => "Build a steady workout",
        "user_id" => -1,
        "origin" => "built_in",
        "state" => "archived",
        "program_json" => %{"forged" => true},
        "content_hash" => "forged",
        "target_reps" => 999,
        "published_at" => DateTime.utc_now(),
        "archived_at" => DateTime.utc_now()
      }

      assert {:ok, draft} = Workouts.create_user_draft(user, attrs)
      assert draft.user_id == user.id
      assert draft.origin == :user
      assert draft.state == :draft
      assert draft.name == "Protected"
      assert draft.request_text == "Build a steady workout"
      assert draft.target_reps == 60
      assert draft.target_duration_sec == 1_200
      assert draft.published_at == nil
      assert draft.archived_at == nil
      refute draft.program_json == %{"forged" => true}
      refute draft.content_hash == "forged"

      assert {:ok, coach_draft} =
               Workouts.create_coach_draft(user, %{
                 "definition" => definition("Coach protected"),
                 "origin" => "built_in",
                 "state" => "published"
               })

      assert coach_draft.user_id == user.id
      assert coach_draft.origin == :coach
      assert coach_draft.state == :draft
    end

    test "invalid replacement leaves the draft byte-for-byte unchanged" do
      user = user_fixture()
      draft = draft_fixture(user, definition("Original"), "original request")
      before = raw_plan_bytes(draft.id)

      invalid = put_in(definition("Invalid replacement"), ["target_reps"], 61)

      assert {:error, %Error{code: :invalid_workout_definition}} =
               Workouts.replace_draft(user, draft.id, %{
                 "definition" => invalid,
                 "request_text" => "failed request"
               })

      assert raw_plan_bytes(draft.id) == before
    end

    test "valid replacement atomically replaces only mutable draft content" do
      user = user_fixture()
      draft = draft_fixture(user, definition("Original"), "original request")

      assert {:ok, replaced} =
               Workouts.replace_draft(user, draft.id, %{
                 "definition" => definition("Replacement", "navy_seal"),
                 "request_text" => "make it navy seal"
               })

      assert replaced.id == draft.id
      assert replaced.user_id == user.id
      assert replaced.origin == :user
      assert replaced.state == :draft
      assert replaced.name == "Replacement"
      assert replaced.request_text == "make it navy seal"
      assert replaced.burpee_type == :navy_seal
      assert replaced.content_hash != draft.content_hash
    end

    test "published and archived content is immutable through draft APIs" do
      user = user_fixture()
      published = published_plan_fixture(user, definition("Published"))
      archived = published_plan_fixture(user, definition("Archived"))
      assert {:ok, archived} = Workouts.archive_plan(user, archived.id)

      for plan <- [published, archived] do
        assert {:error, %Error{code: :workout_immutable}} =
                 Workouts.replace_draft(user, plan.id, %{
                   "definition" => definition("Mutation")
                 })

        assert {:error, %Error{code: :workout_immutable}} =
                 Workouts.delete_draft(user, plan.id)
      end
    end
  end

  describe "publish, copy, archive, and delete" do
    test "publish recompiles stored canonical content and only advances lifecycle" do
      user = user_fixture()
      draft = draft_fixture(user, definition("Publish me"), "request")
      content_before = content_projection(draft)

      assert {:ok, published} = Workouts.publish_draft(user, draft.id)
      assert published.state == :published
      assert %DateTime{} = published.published_at
      assert published.archived_at == nil
      assert content_projection(published) == content_before
      assert {:ok, %WorkoutPlan{id: id}} = Workouts.get_library_plan(user, published.id)
      assert id == published.id
    end

    test "publish rejects a stored program/hash mismatch without changing state" do
      user = user_fixture()
      draft = draft_fixture(user, definition("Corrupted"))

      Repo.query!("UPDATE workout_plans SET content_hash = ? WHERE id = ?", [
        "corrupted-#{System.unique_integer([:positive])}",
        draft.id
      ])

      assert {:error, %Error{code: :infeasible_workout_definition}} =
               Workouts.publish_draft(user, draft.id)

      assert Repo.get!(WorkoutPlan, draft.id).state == :draft
    end

    test "direct publish rejects a recommendation-attached candidate" do
      user = user_fixture()
      fallback = built_in_fallback(user)
      draft = draft_fixture(user, definition("Attached"))
      _recommendation = recommendation_fixture(user, fallback, draft)

      assert {:error, %Error{code: :candidate_attached}} =
               Workouts.publish_draft(user, draft.id)

      assert Repo.get!(WorkoutPlan, draft.id).state == :draft
    end

    test "two users can each copy the same shared built-in" do
      first_user = user_fixture()
      second_user = user_fixture()
      fallback = built_in_fallback(first_user)

      assert {:ok, first_copy} = Workouts.copy_to_draft(first_user, fallback.id)
      assert {:ok, second_copy} = Workouts.copy_to_draft(second_user, fallback.id)
      assert first_copy.content_hash == second_copy.content_hash
      assert first_copy.user_id != second_copy.user_id
    end

    test "one user can repeatedly copy the same shared built-in" do
      user = user_fixture()
      fallback = built_in_fallback(user)

      assert {:ok, first_copy} = Workouts.copy_to_draft(user, fallback.id)
      assert {:ok, second_copy} = Workouts.copy_to_draft(user, fallback.id)
      assert first_copy.id != second_copy.id
      assert first_copy.name == second_copy.name
      assert first_copy.content_hash == second_copy.content_hash
    end

    test "two users can independently create the exact same valid definition" do
      first_user = user_fixture()
      second_user = user_fixture()
      shared_definition = definition("Independent identical draft")

      assert {:ok, first_draft} =
               Workouts.create_user_draft(first_user, %{"definition" => shared_definition})

      assert {:ok, second_draft} =
               Workouts.create_user_draft(second_user, %{"definition" => shared_definition})

      assert first_draft.content_hash == second_draft.content_hash
      assert first_draft.user_id != second_draft.user_id
    end

    test "copy bounds an 80-grapheme source name while preserving the copy suffix" do
      user = user_fixture()
      source_name = String.duplicate("👩‍🚀", 80)
      source = published_plan_fixture(user, definition(source_name))

      assert {:ok, copy} = Workouts.copy_to_draft(user, source.id)
      assert copy.name == String.duplicate("👩‍🚀", 73) <> " (copy)"
      assert copy.name |> String.graphemes() |> length() == 80
    end

    test "copy creates a new user-owned draft from published or archived content" do
      user = user_fixture()
      published = published_plan_fixture(user, definition("Published source"))
      archived = published_plan_fixture(user, definition("Archived source"))
      assert {:ok, archived} = Workouts.archive_plan(user, archived.id)

      for source <- [published, archived] do
        assert {:ok, copy} = Workouts.copy_to_draft(user, source.id)
        assert copy.id != source.id
        assert copy.user_id == user.id
        assert copy.origin == :user
        assert copy.state == :draft
        assert copy.name == source.name <> " (copy)"
        assert copy.published_at == nil
        assert copy.archived_at == nil
      end
    end

    test "archive atomically swaps every selected plan to fallback and preserves candidates byte-for-byte" do
      user = user_fixture()
      selected = published_plan_fixture(user, definition("Selected"))
      fallback = built_in_fallback(user)
      candidate = draft_fixture(user, definition("Pending candidate"))
      with_candidate = recommendation_fixture(user, selected, candidate)
      without_candidate = recommendation_fixture(user, selected, nil)
      candidate_before = raw_plan_bytes(candidate.id)

      assert {:ok, archived} = Workouts.archive_plan(user, selected.id)
      assert archived.state == :archived
      assert %DateTime{} = archived.archived_at

      with_candidate = Repo.get!(CoachRecommendation, with_candidate.id)
      without_candidate = Repo.get!(CoachRecommendation, without_candidate.id)

      assert with_candidate.selected_workout_plan_id == fallback.id
      assert with_candidate.pending_draft_id == candidate.id
      assert without_candidate.selected_workout_plan_id == fallback.id
      assert without_candidate.pending_draft_id == nil
      assert raw_plan_bytes(candidate.id) == candidate_before
    end

    test "only an owned unattached draft can be hard deleted" do
      owner = user_fixture()
      other_user = user_fixture()
      draft = draft_fixture(owner, definition("Delete me"))

      assert {:error, %Error{code: :draft_not_owned}} =
               Workouts.delete_draft(other_user, draft.id)

      assert :ok = Workouts.delete_draft(owner, draft.id)
      assert Repo.get(WorkoutPlan, draft.id) == nil
    end
  end

  describe "database lifecycle triggers" do
    test "direct SQL rejects published content mutation, illegal transitions, and non-draft deletion" do
      user = user_fixture()
      published = published_plan_fixture(user, definition("SQL protected"))
      draft = draft_fixture(user, definition("Illegal transition"))

      assert_raise Exqlite.Error, ~r/workout_plans_immutable_content_check/, fn ->
        Repo.query!("UPDATE workout_plans SET name = 'mutated' WHERE id = ?", [published.id])
      end

      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      assert_raise Exqlite.Error, ~r/workout_plans_state_transition_check/, fn ->
        Repo.query!(
          "UPDATE workout_plans SET state = 'archived', published_at = ?, archived_at = ? WHERE id = ?",
          [now, now, draft.id]
        )
      end

      assert_raise Exqlite.Error, ~r/workout_plans_draft_only_delete_check/, fn ->
        Repo.query!("DELETE FROM workout_plans WHERE id = ?", [published.id])
      end

      assert {:ok, archived} = Workouts.archive_plan(user, published.id)

      assert_raise Exqlite.Error, ~r/workout_plans_draft_only_delete_check/, fn ->
        Repo.query!("DELETE FROM workout_plans WHERE id = ?", [archived.id])
      end
    end
  end

  test "plan fixture persists a published lifecycle plan through state-specific APIs" do
    user = user_fixture()
    plan = plan_fixture(user, %{"name" => "Lifecycle fixture plan"})

    assert plan.state == :published
    assert plan.user_id == user.id
    assert plan.name == "Lifecycle fixture plan"
  end

  test "plan write API surface contains only state-specific lifecycle exports" do
    write_names = [
      :archive_plan,
      :copy_to_draft,
      :create_coach_draft,
      :create_compiled_plan,
      :create_plan,
      :create_user_draft,
      :delete_draft,
      :delete_plan,
      :duplicate_plan,
      :publish_draft,
      :replace_draft,
      :save_generated_plan,
      :update_plan
    ]

    actual =
      Workouts.__info__(:functions)
      |> Enum.filter(fn {name, _arity} -> name in write_names end)
      |> Enum.sort()

    assert actual ==
             Enum.sort(
               archive_plan: 2,
               copy_to_draft: 2,
               create_coach_draft: 2,
               create_user_draft: 2,
               delete_draft: 2,
               publish_draft: 2,
               replace_draft: 3
             )

    refute function_exported?(WorkoutPlan, :changeset, 2)
  end

  defp draft_fixture(user, definition, request_text \\ nil) do
    {:ok, draft} =
      Workouts.create_user_draft(user, %{
        "definition" => definition,
        "request_text" => request_text
      })

    draft
  end

  defp published_plan_fixture(user, definition) do
    draft = draft_fixture(user, definition)
    {:ok, published} = Workouts.publish_draft(user, draft.id)
    published
  end

  defp built_in_fallback(user) do
    Enum.find(Workouts.list_library(user), &(&1.origin == :built_in)) ||
      flunk("expected seeded shared built-in fallback")
  end

  defp recommendation_fixture(user, selected, pending) do
    suffix = System.unique_integer([:positive, :monotonic])

    %CoachRecommendation{
      user_id: user.id,
      slot_key: "lifecycle-#{suffix}",
      slot_date: Date.add(~D[2026-08-29], rem(suffix, 30)),
      selected_workout_plan_id: selected.id,
      pending_draft_id: pending && pending.id,
      rationale: "Lifecycle fixture"
    }
    |> Repo.insert!()
  end

  defp raw_plan_bytes(plan_id) do
    Repo.query!(
      "SELECT request_text, definition_json, program_json, content_hash, name, origin, state, user_id, target_reps, target_duration_sec FROM workout_plans WHERE id = ?",
      [plan_id]
    ).rows
  end

  defp content_projection(plan) do
    Map.take(plan, [
      :user_id,
      :name,
      :origin,
      :request_text,
      :definition_json,
      :program_json,
      :content_hash,
      :burpee_type,
      :target_reps,
      :target_duration_sec
    ])
  end

  defp definition(name, burpee_type \\ "six_count") do
    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => burpee_type,
      "target_reps" => 60,
      "target_duration_sec" => 1_200,
      "pacing_style" => "even",
      "events" => [
        %{
          "kind" => "work",
          "reps" => 30,
          "sec_per_rep" => 18.0,
          "sec_per_burpee" => 6.0
        },
        %{"kind" => "rest", "duration_sec" => 120},
        %{
          "kind" => "work",
          "reps" => 30,
          "sec_per_rep" => 18.0,
          "sec_per_burpee" => 18.0
        }
      ],
      "rationale" => "Two steady efforts with one controlled reset."
    }
  end
end
