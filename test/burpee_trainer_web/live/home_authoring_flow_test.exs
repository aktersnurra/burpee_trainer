defmodule BurpeeTrainerWeb.HomeAuthoringFlowTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainerWeb.HomeAuthoring.Flow

  defp model(attrs \\ []), do: struct!(Flow, attrs)

  describe "opening and leaving the creator" do
    test "New opens only from idle" do
      {opened, []} = Flow.update(model(), {:new_opened, :params, "creator:1"})
      assert opened.authoring_stage == :new
      assert opened.creation_key == "creator:1"
      assert opened.workout_parameters == :params

      assert {^opened, []} = Flow.update(opened, {:new_opened, :other, "creator:2"})
    end

    test "Edit opens only from idle and keeps its source" do
      {opened, []} = Flow.update(model(), {:edit_opened, :source, :params, "variation:1"})
      assert opened.authoring_stage == :editing
      assert opened.editing_source == :source
      assert opened.instruction == ""
    end

    test "aborting New returns to the workout; aborting Edit does not" do
      {from_new, _} = Flow.update(model(authoring_stage: :new), :aborted)
      assert from_new.authoring_stage == :idle
      assert from_new.authoring_returned?

      {from_edit, _} =
        Flow.update(model(authoring_stage: :editing, editing_source: :source), :aborted)

      refute from_edit.authoring_returned?
    end

    test "aborting while a review is in flight cancels it" do
      id = make_ref()

      {aborted, commands} =
        Flow.update(model(authoring_stage: :new, busy?: true, update_id: id), :aborted)

      assert commands == [{:cancel_async, {:new_request, id}}]
      refute aborted.busy?
      assert aborted.update_id == nil
    end
  end

  describe "a review in flight" do
    test "its result is accepted only while it is the current one" do
      a = make_ref()
      b = make_ref()

      {started_a, []} = Flow.update(model(authoring_stage: :new), {:review_started, a, "A"})

      {started_b, [{:cancel_async, {:new_request, ^a}}]} =
        Flow.update(started_a, {:review_started, b, "B"})

      assert started_b.update_id == b

      # A answers late: B is untouched.
      assert {^started_b, []} = Flow.update(started_b, {:review_prepared, a, :prepared_a, :p, []})

      {reviewed, []} = Flow.update(started_b, {:review_prepared, b, :prepared_b, :p, [:row]})
      assert reviewed.authoring_stage == :review
      assert reviewed.pending_request == :prepared_b
      assert reviewed.review_inspection_rows == [:row]
      refute reviewed.busy?
      assert reviewed.update_id == nil
    end

    test "editing the form discards the preparation and ignores its result" do
      id = make_ref()
      {started, _} = Flow.update(model(authoring_stage: :editing), {:review_started, id, "x"})

      {discarded, [{:cancel_async, {:new_request, ^id}}]} =
        Flow.update(started, :preparation_discarded)

      assert {^discarded, []} =
               Flow.update(discarded, {:review_prepared, id, :late, :p, []})
    end

    test "a failure keeps the draft and reports the message" do
      id = make_ref()
      {started, _} = Flow.update(model(authoring_stage: :editing), {:review_started, id, "x"})
      {failed, []} = Flow.update(started, {:review_failed, id, "Coach unavailable."})

      assert failed.authoring_stage == :editing
      assert failed.local_error == "Coach unavailable."
      refute failed.busy?
    end
  end

  describe "approval" do
    test "a saved plan ends the review and asks for fresh alternatives" do
      id = make_ref()

      {confirming, []} =
        Flow.update(
          model(authoring_stage: :review, pending_request: :prepared),
          {:confirm_started, id}
        )

      assert confirming.busy?

      {saved, [:refresh_alternatives]} = Flow.update(confirming, {:plan_saved, id, :plan})
      assert saved.authoring_stage == :saved
      assert saved.created_plan == :plan
      assert saved.pending_request == nil
    end

    test "a failed approval keeps the reviewed request" do
      id = make_ref()

      {confirming, []} =
        Flow.update(
          model(authoring_stage: :review, pending_request: :prepared),
          {:confirm_started, id}
        )

      {failed, []} = Flow.update(confirming, {:plan_failed, id, "Couldn’t produce a plan."})
      assert failed.pending_request == :prepared
      assert failed.authoring_stage == :review
      refute failed.busy?
    end

    test "selecting the created workout returns to idle" do
      {selected, []} =
        Flow.update(model(authoring_stage: :saved, created_plan: :plan), :created_selected)

      assert selected.authoring_stage == :idle
      assert selected.created_plan == nil
    end
  end

  describe "adjusting the selected workout" do
    test "a prepared adjustment is held for confirmation" do
      id = make_ref()
      {asked, []} = Flow.update(model(), {:adjustment_started, id, "shorter"})
      assert asked.busy?
      assert asked.instruction == "shorter"

      {prepared, []} = Flow.update(asked, {:revision_prepared, id, :prepared})
      assert prepared.pending_request == :prepared
      refute prepared.busy?
    end

    test "a failed interpretation clears the pending request" do
      id = make_ref()
      {asked, []} = Flow.update(model(), {:adjustment_started, id, "x"})
      {failed, []} = Flow.update(asked, {:revision_prepare_failed, id, "Couldn’t interpret."})
      assert failed.pending_request == nil
      assert failed.local_error == "Couldn’t interpret."
    end

    test "a blocked confirmation keeps the request; a failed one drops it" do
      id = make_ref()
      base = model(pending_request: :prepared)

      {confirming, []} = Flow.update(base, {:confirm_started, id})
      {blocked, []} = Flow.update(confirming, {:revision_blocked, id, "changed"})
      assert blocked.pending_request == :prepared

      {failed, [:refresh_alternatives]} =
        Flow.update(confirming, {:revision_failed, id, "failed"})

      assert failed.pending_request == nil
    end

    test "going back to the request clears it" do
      {back, []} =
        Flow.update(model(pending_request: :prepared, local_error: "x"), :request_reopened)

      assert back.pending_request == nil
      assert back.local_error == nil
    end
  end

  test "current?/2 is true only for the operation in flight" do
    id = make_ref()
    assert Flow.current?(model(update_id: id), id)
    refute Flow.current?(model(update_id: id), make_ref())
    refute Flow.current?(model(), nil)
  end

  test "assigns round-trip through the model" do
    assigns = %{authoring_stage: :new, busy?: true, unrelated: 1}
    flow = Flow.from_assigns(assigns)
    assert flow.authoring_stage == :new
    refute Keyword.has_key?(Flow.to_assigns(flow), :unrelated)
  end
end
