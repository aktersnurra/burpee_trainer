# Adaptive Home Pre-workout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Current scope revision:** Continue with [Adaptive Home: Inline State-Machine Plan Revision](2026-09-12-adaptive-home-inline-revision.md). It preserves this pre-workout implementation as the baseline and supersedes permanent separate Library/Create destinations with inline Home flows. The tasks below are historical implementation detail, not a new execution queue. Preserve their compiler, ownership, privacy and atomic-Start guarantees.

**Goal:** Deliver the approved real-data pre-workout Home: stable selection, exact inspection, inline revision, filtered alternatives, and atomic Start.

**Architecture:** Extend the existing recommendation with one stable Home pointer/revision. Keep compiler validation, immutable library content, and session snapshots authoritative; add an owned append-only design context and identity-only best-effort finalization notifications. Provider work stays outside transactions and outside the LiveView process.

**Tech Stack:** Phoenix 1.8/LiveView, Elixir, Ecto/SQLite, Req, PubSub, supervised tasks, Tailwind v4, ExUnit, Node, isolated authenticated Firefox.

## Global Constraints

- “The existing workout compiler, immutable published library, session snapshots, and authentication remain authoritative.”
- “The automatic recommendation is either a valid new draft or an eligible published structured workout. **It is never a video.**”
- “Reopening Home alone must not reshuffle the recommendation.”
- “Group **consecutive identical** sets or blocks into one summary row.”
- “Equality must compare exact workout data, including timing and rests, not rounded display strings.”
- “Expanding/collapsing is presentation only. Never rewrite the canonical definition or program for display grouping.”
- “There is no separate Save, Publish, Use this workout, or Copy & adjust step on Home.”
- “Display **only the loading animation in its place**.”
- “At most 500 graphemes and 4,000 bytes per instruction; at most one provider request per user update; no automatic multi-call repair.”
- “For a draft, finalization and creation of the immutable started-session snapshot form one atomic operation.”
- “Do not silently truncate design history.”
- “This memory update is **best effort**. Missing an event is acceptable.”
- “Do not add Kafka, an outbox, delivery tracking, replay, durable retry jobs, or recovery machinery for this callback.”
- “Use approximately 240–300 ms restrained transitions; honor reduced-motion preferences.”
- “Expanded content and accessibility text may scroll. Never shrink text to force a fit.”
- For this original pre-workout slice, preserve existing Create/library work and leave History, checkpoint/recovery, weekly-policy, and global-feedback surfaces separate. The linked inline state-machine revision governs follow-on consolidation; it does not authorize deleting baseline functionality without replacement coverage.
- Use existing authenticated routes, `<Layouts.app>`, `<.input>`, `<.icon>`, semantic tables, and streams. No new dependencies, animation framework, inline scripts, or provider request on Home mount.

---

## Authority and protected baseline

Read `docs/superpowers/specs/2026-09-09-adaptive-home-pre-workout-design.md`, its three linked reference captures, `AGENTS.md`, and `docs/testing/workout-session-e2e.md`. Visual tweaks are deferred.

Read-only `jj status`/`jj diff --stat` confirmed `zqwrpnkmwwkv / 486038087e98`, parent `2054968df11e`, and these eleven pre-existing changes:

```text
assets/css/app.css
lib/burpee_trainer/workouts.ex
lib/burpee_trainer_web/components/workout_draft_structure.ex
lib/burpee_trainer_web/components/workout_library_components.ex
lib/burpee_trainer_web/live/creation_parameters.ex
lib/burpee_trainer_web/live/workout_creation_live.ex
lib/burpee_trainer_web/live/workout_creation_live.html.heex
lib/burpee_trainer_web/live/workout_library_live.ex
lib/burpee_trainer_web/router.ex
test/burpee_trainer_web/live/creation_parameters_test.exs
test/burpee_trainer_web/live/workout_creation_live_test.exs
```

This correction pass changes **only this plan artifact**. No source, tests, provider requests, deployments, VCS writes, or browser runs are authorized during planning. During implementation the parent must isolate/preserve the baseline before commits; use read-only `jj diff` review checkpoints until then. Never replace a protected file with the parent revision.

### Verified seams and compatibility

- `lib/burpee_trainer/workouts.ex`: `ensure_recommendation/2`, `get_library_plan/2`, `get_draft/2`, `replace_draft/3`, `accept_candidate/4`, `publish_and_start_draft/3`, `start_plan/3`, `start_video/3`, `current_started_session/1` exist. The creator's `publish_and_start_draft/3` is baseline functionality, not missing scaffolding.
- Existing private helpers reused below, in that same module: `immediate_lifecycle_transaction/1`, `built_in_fallback/0`, `current_candidate/4`, `current_recommendation_selection/1`, `compare_expected_draft_revision/2`, `canonical_draft_content/1`, `verify_stored_draft/1`, `normalize_plan_write/1`, `publish_unattached_draft/2`, `get_available_video_for_start/1`, `lifecycle_now/0`.
- `start_session/3` currently reuses a token without comparing its source. Task 2 closes that hole. Ecto nested transactions are not independent commits; the outer Home transaction owns candidate publication and session insertion.
- `lib/burpee_trainer/coach.ex`: `validate_authoring_input/1`, `validate_provider_definition/1`, `refinable_draft/2`, and `@authoring_system_prompt` already exist. Keep these validation helpers and the public creator APIs.
- `Client.complete/2` currently enforces a workout-definition schema even when the reconciler asks for a proposal. Task 3 introduces a closed response-kind option, not another client/service.
- `Levels.all_levels/0` is descending. `Levels.level_for_count/2` is a real count-only tag; `Levels.current_level/2` is maintained overall achievement. Do not confuse them.
- Definition v1 is a flat event list. Compiler v3 uses microsecond work timing, millisecond rest timing, and terminal duration `(reps - 1) * cadence + active`; nonterminal work uses `reps * cadence`.
- `WorkoutDraftStructure.structure/1` is the existing creator's literal renderer. Leave it intact; Home gets a separate lossless projection.
- **Layout verified again:** `lib/burpee_trainer_web/components/layouts.ex:14–21` declares `flash`, `current_user`, `current_level`, **`current_scope`**, `current_page`, `navigation?`, and `flash?`. No compatibility edit is needed. Auth actually assigns `current_user`/`current_level`; pass `current_scope={assigns[:current_scope]}` exactly as the current creator does. Do not invent `@current_scope` as a required authenticated assign.
- Hook registration is in `assets/js/app_bootstrap.js`, not another LiveSocket.

### Supervisor-approved planning decisions, for owner review

1. Known-count catalog tags use `Levels.level_for_count/2`, including long plans; no achievement/PB normalization changes. Unknown-count videos are excluded by active level filters but remain in the existing Videos surface.
2. Optional ordered published plan IDs come in the existing bounded coach response. Persist them; append omitted eligible plans in stable order: slot-type match, duration distance, level distance, name, ID. Videos use ascending known level/name/ID. No extra ranking request/job.
3. Identical adjacent sets collapse first. Nonuniform repeat groups use the shortest exact repeating unit over its maximal adjacent run. These are not inferred authored block entities.
4. The existing recommendation gets `home_workout_plan_id` and monotonic `home_revision`. First presentation atomically pins pending draft or published fallback. Reopening/ranking/late candidate responses cannot overwrite a valid pin. Explicit selection/revision changes it. Invalid/deleted/archived pins converge to fallback and invalidate stale clients.
5. **Design identity correction:** unique `{user_id, workspace_key}`, allocated server-side. Published-source Home attempts use `home:<recommendation_id>:<reviewed_home_revision>`; failed attempts and reloads reuse it. Owned mutable drafts continue their own context, or initialize `draft:<id>`. Independent published-source selections always get a fresh writable context—even for the same owner. Full prior owned history may be copied once into an immutable imported baseline, never shared as a writable log. Shared sources contribute only public canonical definition/program data, never their author's request text/private history.
6. Creator new-workout UUIDs are allocated once per authoring workspace and retained across failed retries. No candidate ancestry graph or new Home pin/job entity.
7. Messages identify the active attempt explicitly and include the complete context snapshot, so another concurrent instruction cannot become this request's instruction.
8. The aggregate serialized request cap is 262,144 bytes before HTTP, distinct from the existing response cap. No history truncation.
9. Finalization memory is conservative workout facts/scoped reasons, not inferred global preferences. Event loss is acceptable.

## File map and execution conventions

New files: `lib/burpee_trainer/workouts/{home_selection,inspection,finalization}.ex`; `lib/burpee_trainer/coach/{catalog,design_session,design_entry,context,setting,workout_memory,memory,memory_subscriber}.ex`; `lib/burpee_trainer_web/live/home_adjustment.ex`; `lib/burpee_trainer_web/components/home_workout_components.ex`; `assets/js/hooks/home_adjustment.mjs`; `assets/css/adaptive_home.css`.

Modify narrowly: `workouts.ex`, `workouts/{workout_plan,coach_recommendation}.ex`, `coach.ex`, `coach/{client,recommendation}.ex`, `coach_reconciler.ex`, `videos.ex`, `application.ex`, `overview_live.ex`, creator's UUID plumbing only, `assets/js/app_bootstrap.js`, and one CSS import. Test paths are listed per task.

Generate migrations during implementation with `mix ecto.gen.migration add_adaptive_home_selection`, `add_coach_catalog_order`, and `add_workout_design_context`. Read `mix help ecto.gen.migration` first. The generator owns timestamped filenames; record the emitted exact paths in the execution log before editing. Do not invent future timestamps or edit historical migrations.

Each numbered checkpoint below is a separate red/green/review gate. Commands are for **future implementation**, not this planning pass. New functions are supplied below; helpers not supplied are explicitly mapped to current source above. Use existing `Error.new/1,2` for domain errors. Avoid `Process.sleep/1` in new tests.

---

## Task 1: Stable Home pointer and exact selection checks

**Files:** new `lib/burpee_trainer/workouts/home_selection.ex`; modify `lib/burpee_trainer/workouts.ex`, `lib/burpee_trainer/workouts/coach_recommendation.ex`; migration `add_adaptive_home_selection`; new `test/burpee_trainer/workouts/home_selection_test.exs`.

**Contracts:** `ensure_home_selection(user, Policy.slot())`, `select_home_workout(user, HomeSelection.t(), plan_id)` return `{:ok, HomeSelection.t()} | {:error, Error.t()}`. `verify_home_selection/2` returns the exact current `WorkoutPlan` or error. Reading/pinning never invokes the provider or compiles the catalog.

- [ ] **1A red:** add this test module, run `mix test test/burpee_trainer/workouts/home_selection_test.exs`; expect missing API failures.

```elixir
defmodule BurpeeTrainer.Workouts.HomeSelectionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Error}

  setup do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    %{user: user, slot: slot}
  end

  test "reload is stable and another tab cannot overwrite selection", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(u, slot)
    assert {:ok, ^a} = Workouts.ensure_home_selection(u, slot)
    plan = plan_fixture(u)
    {:ok, b} = Workouts.select_home_workout(u, a, plan.id)
    assert b.home_revision == a.home_revision + 1
    assert {:error, %Error{code: :home_selection_changed}} =
      Workouts.select_home_workout(u, a, a.plan.id)
    assert {:ok, ^b} = Workouts.ensure_home_selection(u, slot)
  end

  test "foreign selection is rejected without changing the pin", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(u, slot)
    foreign = plan_fixture(user_fixture())
    assert {:error, _} = Workouts.select_home_workout(u, a, foreign.id)
    assert {:ok, ^a} = Workouts.ensure_home_selection(u, slot)
  end

  test "archived pin falls back with a new revision", %{user: u, slot: slot} do
    {:ok, a} = Workouts.ensure_home_selection(u, slot)
    plan = plan_fixture(u)
    {:ok, b} = Workouts.select_home_workout(u, a, plan.id)
    {:ok, _} = Workouts.archive_plan(u, plan.id)
    {:ok, c} = Workouts.ensure_home_selection(u, slot)
    assert c.plan.origin == :built_in
    assert c.home_revision > b.home_revision
    assert {:error, _} = Workouts.verify_home_selection(u, b)
  end

  test "legacy automatic video is normalized without starting it", %{user: u, slot: slot} do
    {:ok, r} = Workouts.ensure_recommendation(u, Map.take(slot, [:slot_key, :slot_date]))
    video = video_fixture()
    {:ok, _} = Workouts.select_recommendation(u, r.id, {:video, video.id}, "Legacy")
    {:ok, shown} = Workouts.ensure_home_selection(u, slot)
    assert shown.plan.origin == :built_in
    assert Repo.get!(CoachRecommendation, r.id).selected_workout_video_id == nil
    assert Workouts.current_started_session(u) == nil
  end
end
```

- [ ] **1A green:** migration body and schema fields:

```elixir
def change do
  alter table(:coach_recommendations) do
    add :home_workout_plan_id, references(:workout_plans, on_delete: :nilify_all)
    add :home_revision, :integer, null: false, default: 0
  end
  create index(:coach_recommendations, [:home_workout_plan_id])
end
```

```elixir
# Inside CoachRecommendation.schema, not its generic cast lists:
field :home_revision, :integer, default: 0
belongs_to :home_workout_plan, WorkoutPlan
```

```elixir
defmodule BurpeeTrainer.Workouts.HomeSelection do
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan}
  @enforce_keys [:recommendation_id, :home_revision, :plan, :recommendation_selection,
    :pending_draft_id]
  defstruct @enforce_keys
  @type t :: %__MODULE__{recommendation_id: pos_integer(), home_revision: non_neg_integer(),
    plan: WorkoutPlan.t(), recommendation_selection: CoachRecommendation.selection(),
    pending_draft_id: pos_integer() | nil}

  def new(r, plan) do
    selected = if r.selected_workout_plan_id,
      do: {:plan, r.selected_workout_plan_id}, else: {:video, r.selected_workout_video_id}
    %__MODULE__{recommendation_id: r.id, home_revision: r.home_revision, plan: plan,
      recommendation_selection: selected, pending_draft_id: r.pending_draft_id}
  end
end
```

Add the following functions **inside existing Workouts**, with `alias BurpeeTrainer.Workouts.HomeSelection`. Keep existing private helpers and their behavior.

```elixir
def ensure_home_selection(%User{} = user, slot) do
  immediate_lifecycle_transaction(fn ->
    with {:ok, r} <- ensure_recommendation(user, Map.take(slot, [:slot_key, :slot_date])),
         {:ok, r} <- ensure_recommendation_selection_available(user, r.id) do
      case home_plan(user, r.home_workout_plan_id) do
        {:ok, plan} -> {:ok, HomeSelection.new(r, plan)}
        {:error, _} ->
          with {:ok, plan} <- initial_home_plan(user, r),
               {:ok, pinned} <- write_home_pointer(r, plan.id) do
            {:ok, HomeSelection.new(pinned, plan)}
          end
      end
    end
  end)
end

def select_home_workout(%User{} = user, %HomeSelection{} = expected, id) do
  immediate_lifecycle_transaction(fn ->
    with {:ok, r} <- home_recommendation(user, expected),
         {:ok, plan} <- selectable_home_plan(user, r, id),
         :ok <- verify_stored_draft(plan),
         {:ok, changed} <- write_home_pointer(r, plan.id) do
      {:ok, HomeSelection.new(changed, plan)}
    end
  end)
end

def verify_home_selection(%User{} = user, %HomeSelection{} = expected) do
  with {:ok, _r} <- home_recommendation(user, expected),
       {:ok, plan} <- home_plan(user, expected.plan.id),
       :ok <- compare_expected_draft_revision(plan, %{expected_revision: expected.plan}),
       :ok <- verify_stored_draft(plan) do
    {:ok, plan}
  end
end

def verify_plan_content(%WorkoutPlan{} = plan), do: verify_stored_draft(plan)

def design_source(%User{} = user, id), do: home_plan(user, id)

defp home_recommendation(user, expected) do
  with %CoachRecommendation{} = r <-
         Repo.get_by(CoachRecommendation, id: expected.recommendation_id, user_id: user.id),
       {:ok, slot} <- Policy.required_slot(user, DateTime.utc_now(:second)),
       true <- r.slot_key == slot.slot_key and slot.home_state == :workout_needed,
       true <- r.home_workout_plan_id == expected.plan.id and
         r.home_revision == expected.home_revision do
    {:ok, r}
  else
    _ -> {:error, Error.new(:home_selection_changed)}
  end
end

defp home_plan(user, id) when is_integer(id) and id > 0 do
  case get_draft(user, id) do
    {:ok, plan} -> {:ok, plan}
    {:error, _} -> get_library_plan(user, id)
  end
end

defp home_plan(_user, _id), do: {:error, Error.new(:source_unavailable)}

defp initial_home_plan(user, %{home_revision: 0} = r) do
  case home_plan(user, r.pending_draft_id) do
    {:ok, %{state: :draft} = draft} -> {:ok, draft}
    _ ->
      case get_library_plan(user, r.selected_workout_plan_id) do
        {:ok, plan} -> {:ok, plan}
        _ -> built_in_fallback()
      end
  end
end

# A removed/invalid prior pin must not promote a late unrelated candidate.
defp initial_home_plan(_user, _r), do: built_in_fallback()

defp selectable_home_plan(user, %{pending_draft_id: id}, id)
     when is_integer(id), do: get_draft(user, id)
defp selectable_home_plan(user, _r, id), do: get_library_plan(user, id)

defp write_home_pointer(r, id) do
  case r |> Ecto.Changeset.change(home_workout_plan_id: id,
         home_revision: r.home_revision + 1) |> Repo.update() do
    {:ok, changed} -> {:ok, changed}
    {:error, _} -> {:error, Error.new(:home_selection_changed)}
  end
end
```

In existing `recommendation_selection_available?/2`, change only the video branch to `{:video, _video_id} -> false`. This normalizes automatic legacy video pointers through the existing fallback boundary, preserving pending candidates. Explicit video sessions still use `start_video/3`.

- [ ] **1B red/green:** append this regression; run it before wiring the new pin and after. Existing `ensure_recommendation/2` returns the current slot row and never compiles on mount.

```elixir
test "late candidate and explicit selection preserve each other's identities", %{user: u, slot: slot} do
  {:ok, shown} = Workouts.ensure_home_selection(u, slot)
  d = workout_plan_draft_fixture(u, %{target_duration_sec: slot.duration_sec,
    burpee_type: Atom.to_string(slot.burpee_type), target_reps: 10})
  candidate = Repo.get!(CoachRecommendation, shown.recommendation_id)
    |> Ecto.Changeset.change(pending_draft_id: d.id) |> Repo.update!()
  {:ok, reopened} = Workouts.ensure_home_selection(u, slot)
  assert reopened.plan.id == shown.plan.id
  assert reopened.home_revision == shown.home_revision
  alternative = plan_fixture(u)
  {:ok, selected} = Workouts.select_home_workout(u, reopened, alternative.id)
  assert Repo.get!(CoachRecommendation, selected.recommendation_id).pending_draft_id ==
    candidate.pending_draft_id
end
```

- [ ] **Review gate:** `mix test test/burpee_trainer/workouts/home_selection_test.exs test/burpee_trainer/workouts/recommendation_lifecycle_test.exs`; `jj diff -- lib/burpee_trainer/workouts.ex`. Do not commit protected work.

---

## Task 2: Atomic source-bound Start, including attached candidates and direct videos

**Files:** modify `lib/burpee_trainer/workouts.ex`; extend `test/burpee_trainer/workouts/{home_selection,recommendation_lifecycle,workout_session_lifecycle}_test.exs`; preserve creator tests.

**Contracts:** `start_home_workout(user, expected, uuid)` and `start_home_video(user, expected, video_id, uuid)` return `{:ok, WorkoutSession.t()} | {:error, Error.t()}`. Preserve `publish_and_start_draft/3`, `accept_candidate/4`, `start_plan/3`, `start_video/3`.

- [ ] **2A red:** add the following tests to Task 1's module; run the focused file before adding APIs.

```elixir
test "wrong-source token and stale pin cannot start", %{user: u, slot: slot} do
  {:ok, shown} = Workouts.ensure_home_selection(u, slot)
  other = plan_fixture(u)
  token = Ecto.UUID.generate()
  {:ok, existing} = Workouts.start_plan(u, other.id, token)
  assert {:error, %Error{code: :start_token_source_mismatch}} =
    Workouts.start_home_workout(u, shown, token)
  assert Workouts.current_started_session(u).id == existing.id
  {:ok, changed} = Workouts.select_home_workout(u, shown, other.id)
  assert changed.home_revision > shown.home_revision
  assert {:error, %Error{code: :home_selection_changed}} =
    Workouts.start_home_workout(u, shown, Ecto.UUID.generate())
end

test "exact duplicate Start reuses one snapshot", %{user: u, slot: slot} do
  {:ok, shown} = Workouts.ensure_home_selection(u, slot)
  token = Ecto.UUID.generate()
  {:ok, first} = Workouts.start_home_workout(u, shown, token)
  assert {:ok, again} = Workouts.start_home_workout(u, shown, token)
  assert again.id == first.id
  assert first.program_snapshot == shown.plan.program_json
end

test "video selection starts directly and does not change the pin", %{user: u, slot: slot} do
  {:ok, shown} = Workouts.ensure_home_selection(u, slot)
  video = video_fixture(%{burpee_count: 100})
  {:ok, session} = Workouts.start_home_video(u, shown, video.id, Ecto.UUID.generate())
  assert session.source_kind == :video
  assert session.workout_video_id == video.id
  assert session.plan_id == nil
  assert {:ok, same} = Workouts.ensure_home_selection(u, slot)
  assert same.plan.id == shown.plan.id
  assert same.home_revision == shown.home_revision
end
```

- [ ] **2A green:** add full boundaries in Workouts. `Finalization.deliver/1` is defined immediately below, so this task is independently compilable. Existing acceptance remains nested inside the single outer transaction; no intermediate publication commit occurs.

```elixir
def start_home_workout(user, %HomeSelection{} = expected, token) do
  immediate_lifecycle_transaction(fn ->
    with :ok <- valid_start_token(token),
         {:ok, _r} <- home_recommendation(user, expected),
         :new <- existing_start(user.id, token, :plan, expected.plan.id,
           expected.plan.content_hash),
         :ok <- no_other_started_session(user),
         {:ok, plan} <- verify_home_selection(user, expected),
         {:ok, published} <- finalize_home_plan(user, expected, plan),
         {:ok, session} <- start_plan(user, published.id, token) do
      finalized = if plan.state == :draft, do: published, else: nil
      {:ok, {session, finalized}}
    else
      {:existing, session} -> {:ok, {session, nil}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end)
  |> BurpeeTrainer.Workouts.Finalization.deliver()
end

def start_home_video(user, expected, video_id, token) do
  immediate_lifecycle_transaction(fn ->
    with :ok <- valid_start_token(token),
         {:ok, _r} <- home_recommendation(user, expected),
         {:ok, video} <- get_available_video_for_start(video_id),
         {:ok, _snapshot, hash} <- ProgramHash.video_snapshot(%{
           "name" => video.name, "filename" => video.filename,
           "type" => Atom.to_string(video.burpee_type), "duration" => video.duration_sec,
           "count" => video.burpee_count, "format" => Atom.to_string(video.format)}),
         :new <- existing_start(user.id, token, :video, video.id, hash),
         :ok <- no_other_started_session(user) do
      start_video(user, video.id, token)
    else
      {:existing, session} -> {:ok, session}
      {:error, %Error{} = error} -> {:error, error}
    end
  end)
end

defp finalize_home_plan(_user, _expected, %{state: :published} = plan), do: {:ok, plan}
defp finalize_home_plan(user, expected, %{state: :draft} = plan) do
  if expected.pending_draft_id == plan.id do
    with {:ok, _} <- accept_candidate(user, expected.recommendation_id, plan.id,
           expected.recommendation_selection) do
      get_library_plan(user, plan.id)
    end
  else
    publish_unattached_draft(user, plan.id)
  end
end

defp valid_start_token(token) do
  case Ecto.UUID.cast(token) do
    {:ok, ^token} -> :ok
    _ -> {:error, Error.new(:invalid_start_token)}
  end
end

defp no_other_started_session(user) do
  if current_started_session(user), do: {:error, Error.new(:session_in_progress)}, else: :ok
end

defp existing_start(user_id, token, kind, id, hash) do
  case Repo.get_by(WorkoutSession, user_id: user_id, client_session_id: token) do
    nil -> :new
    session ->
      source_id = if session.source_kind == :plan, do: session.plan_id,
        else: session.workout_video_id
      if session.source_kind == kind and source_id == id and session.content_hash == hash,
        do: {:existing, session}, else: {:error, Error.new(:start_token_source_mismatch)}
  end
end
```

Create `lib/burpee_trainer/workouts/finalization.ex` now (Task 7 adds its subscriber):

```elixir
defmodule BurpeeTrainer.Workouts.Finalization do
  alias BurpeeTrainer.Repo

  def deliver({:ok, {value, nil}}), do: {:ok, value}
  def deliver({:ok, {value, plan}}) do
    notify(plan)
    {:ok, value}
  end
  def deliver({:error, _} = error), do: error

  def notify(plan) do
    unless Repo.in_transaction?() do
      Phoenix.PubSub.broadcast(BurpeeTrainer.PubSub, "workout_finalized",
        {:workout_finalized, %{user_id: plan.user_id, workout_plan_id: plan.id,
          design_session_id: Map.get(plan, :design_session_id)}})
    end
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
```

Replace the **body only** of the existing `publish_and_start_draft/3`; do not remove its public API or creator reviewed-revision check:

```elixir
def publish_and_start_draft(%User{} = user, %WorkoutPlan{} = expected, token) do
  immediate_lifecycle_transaction(fn ->
    with :ok <- valid_start_token(token),
         :new <- existing_start(user.id, token, :plan, expected.id, expected.content_hash),
         {:ok, draft} <- get_draft(user, expected.id),
         :ok <- compare_expected_draft_revision(draft, %{expected_revision: expected}),
         {:ok, published} <- publish_unattached_draft(user, draft.id),
         {:ok, session} <- start_plan(user, published.id, token) do
      {:ok, {session, published}}
    else
      {:existing, session} -> {:ok, {session, nil}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end)
  |> BurpeeTrainer.Workouts.Finalization.deliver()
end
```

In existing `start_session/3`, replace the callback passed to `Repo.immediate_transaction/1` with this exact callback; preserve its existing result normalization after the transaction. It closes wrong-source reuse for non-Home callers too:

```elixir
fn ->
  with :ok <- valid_start_token(client_session_id),
       {:ok, proposed} <- source.() do
    id = if proposed.source_kind == :plan, do: proposed.plan_id,
      else: proposed.workout_video_id
    case existing_start(user_id, client_session_id, proposed.source_kind, id,
           proposed.content_hash) do
      {:existing, session} -> session
      :new ->
        case proposed |> WorkoutSession.start_changeset() |> Repo.insert() do
          {:ok, inserted} -> inserted
          {:error, changeset} -> Repo.rollback(changeset)
        end
      {:error, error} -> Repo.rollback(error)
    end
  else
    {:error, error} -> Repo.rollback(error)
  end
end
```

- [ ] **2B red/green:** add the following fixture helper and tests in `recommendation_lifecycle_test.exs`. Its old `ensure/1` uses a fixed 2025 date and cannot initialize today's Home. This helper creates a current-slot recommendation and a compiler-valid attached draft, through the existing changesets; automatic policy remains covered by the existing recommendation tests.

```elixir
defp attached_home_fixture(user, name) do
  {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
  {:ok, slot} = BurpeeTrainer.Coach.Policy.required_slot(user, DateTime.utc_now(:second))
  {:ok, r} = Workouts.ensure_recommendation(user, Map.take(slot, [:slot_key, :slot_date]))
  draft = workout_plan_draft_fixture(user, %{name: name})
  r = r |> Ecto.Changeset.change(pending_draft_id: draft.id) |> Repo.update!()
  {user, r, slot}
end

test "attached Home finalization is atomic on invalid token and corrupt content" do
  {user, r, slot} = attached_home_fixture(user_fixture(), "Atomic candidate")
  {:ok, shown} = Workouts.ensure_home_selection(user, slot)
  assert shown.plan.id == r.pending_draft_id
  assert {:error, _} = Workouts.start_home_workout(user, shown, "bad-token")
  Repo.update_all(from(p in WorkoutPlan, where: p.id == ^shown.plan.id),
    set: [content_hash: "corrupt"])
  assert {:error, _} = Workouts.start_home_workout(user, shown, Ecto.UUID.generate())
  assert Repo.get!(WorkoutPlan, shown.plan.id).state == :draft
  assert Repo.get!(CoachRecommendation, r.id).pending_draft_id == shown.plan.id
  assert Workouts.current_started_session(user) == nil
end

test "candidate publication, pointer, and exact snapshot commit together" do
  {user, r, slot} = attached_home_fixture(user_fixture(), "Start me")
  {:ok, shown} = Workouts.ensure_home_selection(user, slot)
  {:ok, session} = Workouts.start_home_workout(user, shown, Ecto.UUID.generate())
  persisted = Repo.get!(CoachRecommendation, r.id)
  assert persisted.pending_draft_id == nil
  assert persisted.selected_workout_plan_id == shown.plan.id
  assert session.program_snapshot == shown.plan.program_json
  assert session.content_hash == shown.plan.content_hash
end
```

- [ ] **Review gate:** run the three lifecycle files plus `test/burpee_trainer_web/live/workout_creation_live_test.exs`. Existing snapshot/ownership/ABA tests remain; no recovery product behavior is added.

---

## Task 3: Domain catalog levels and optional persisted coach order

**Files:** create `lib/burpee_trainer/coach/catalog.ex`; modify `videos.ex`, `coach/{client,recommendation}.ex`, `coach_reconciler.ex`, `workouts/coach_recommendation.ex`; migration `add_coach_catalog_order`; tests `test/burpee_trainer/coach/{catalog,client,recommendation}_test.exs` and `test/burpee_trainer/coach_reconciler_test.exs`.

**Contracts:** `Catalog.default_filters/1`, `plan_level/1`, `video_level/1`, `order_plans/4`, `order_videos/1`, `filter/3`; `Videos.list_home_videos/0`; `Recommendation.json_schema/0`; `Client.complete/2` accepts only the response kinds `:workout_definition` (default) and `:coach_recommendation`.

- [ ] **3A red:** add pure tests to `catalog_test.exs`, run that file; expect missing functions.

```elixir
defmodule BurpeeTrainer.Coach.CatalogTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Coach.Catalog
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutVideo}

  test "real current-next defaults and unknown video exclusion" do
    assert Catalog.default_filters(:level_1c).levels == MapSet.new([:level_1c, :level_1d])
    assert Catalog.default_filters(:graduated).levels == MapSet.new([:graduated])
    assert Catalog.video_level(%WorkoutVideo{burpee_type: :six_count, burpee_count: nil}) == nil
    assert Catalog.plan_level(%WorkoutPlan{burpee_type: :six_count, target_reps: 200,
      target_duration_sec: 2400}) == :level_2
  end

  test "filtering preserves the coach-ranked subsequence" do
    plans = for {id, type, reps} <- [{1, :six_count, 100}, {2, :navy_seal, 40},
      {3, :six_count, 150}], do: %WorkoutPlan{id: id, name: "Plan #{id}", burpee_type: type,
        target_reps: reps, target_duration_sec: 1200}
    ranked = Catalog.order_plans(plans, [2, 3, 2, 999],
      %{burpee_type: :six_count, duration_sec: 1200}, :level_1c)
    assert Enum.map(ranked, & &1.id) == [2, 3, 1]
    filters = %{types: MapSet.new([:six_count]), levels: MapSet.new([:level_1c, :level_1d])}
    assert Enum.map(Catalog.filter(ranked, filters, &Catalog.plan_level/1), & &1.id) == [3, 1]
  end
end
```

- [ ] **3A green:** complete pure implementation:

```elixir
defmodule BurpeeTrainer.Coach.Catalog do
  alias BurpeeTrainer.Levels
  def default_filters(level) do
    levels = Enum.reverse(Levels.all_levels())
    index = Enum.find_index(levels, &(&1 == level))
    %{types: MapSet.new([:six_count, :navy_seal]),
      levels: MapSet.new(Enum.slice(levels, index, 2))}
  end
  def plan_level(p), do: Levels.level_for_count(p.burpee_type, p.target_reps)
  def video_level(%{burpee_count: n, burpee_type: t}) when is_integer(n) and n > 0,
    do: Levels.level_for_count(t, n)
  def video_level(_), do: nil
  def filter(items, filters, level_fun), do: Enum.filter(items, fn item ->
    MapSet.member?(filters.types, item.burpee_type) and
      MapSet.member?(filters.levels, level_fun.(item))
  end)
  def order_plans(plans, ids, slot, level) do
    by_id = Map.new(plans, &{&1.id, &1})
    first = ids |> Enum.filter(&Map.has_key?(by_id, &1)) |> Enum.uniq()
      |> Enum.map(&Map.fetch!(by_id, &1))
    used = MapSet.new(first, & &1.id)
    rest = plans |> Enum.reject(&MapSet.member?(used, &1.id)) |> Enum.sort_by(fn p ->
      {if(p.burpee_type == slot.burpee_type, do: 0, else: 1),
       abs(p.target_duration_sec - slot.duration_sec),
       abs(index(plan_level(p)) - index(level)), String.downcase(p.name), p.id}
    end)
    first ++ rest
  end
  def order_videos(videos), do: videos |> Enum.reject(&(video_level(&1) == nil))
    |> Enum.sort_by(&{index(video_level(&1)), String.downcase(&1.name), &1.id})
  defp index(level), do: Enum.find_index(Enum.reverse(Levels.all_levels()), &(&1 == level))
end
```

Add to `Videos` using its existing `Repo`, `WorkoutVideo`, and `Ecto.Query` imports:

```elixir
def list_home_videos do
  Repo.all(from v in WorkoutVideo,
    where: v.available == true and v.format == :follow_along,
    order_by: [asc: v.name, asc: v.id])
end
```

This query is uncapped: the existing 24-row coach-evidence limit must not discard Home results before filtering.

- [ ] **3B red:** add this complete test to `recommendation_test.exs`, using its fixture imports and `Recommendation`/`Workouts` aliases. A fixed weekday slot makes the automatic-policy test independent of the date it runs.

```elixir
test "optional ranking discards foreign and duplicate IDs without changing Home state" do
  user = user_fixture()
  {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
  {:ok, before} = Workouts.ensure_recommendation(user,
    %{slot_key: "catalog-order-test", slot_date: ~D[2025-09-01]})
  plan = plan_fixture(user)
  foreign = plan_fixture(user_fixture())
  response = %{"action" => "select_existing", "workout_plan_id" => plan.id,
    "rationale" => "Eligible structured workout",
    "ranked_workout_plan_ids" => [plan.id, foreign.id, plan.id, 999_999]}
  assert {:ok, applied} = Recommendation.apply_proposal(user, before.id, response,
    {:plan, before.selected_workout_plan_id})
  assert applied.ranked_plan_ids == %{"ids" => [plan.id]}
  assert applied.home_revision == before.home_revision
  assert applied.home_workout_plan_id == before.home_workout_plan_id
end
```

- [ ] **3B green:** migration/schema:

```elixir
def change do
  alter table(:coach_recommendations) do
    add :ranked_plan_ids, :map, null: false, default: %{}
  end
end
# CoachRecommendation.schema:
field :ranked_plan_ids, :map, default: %{}
```

In `Recommendation.apply_proposal/4`, retain the existing parse/policy `with`, replacing only its successful call to `apply_verified_proposal/4` with `apply_with_order(user, recommendation_id, proposal, expected_selection, response)`. Add:

```elixir
defp apply_with_order(user, id, proposal, expected, response) do
  Repo.immediate_transaction(fn ->
    case apply_verified_proposal(user, id, proposal, expected) do
      {:ok, recommendation} ->
        ids = case response["ranked_workout_plan_ids"] do
          ids when is_list(ids) and length(ids) <= 256 -> ids
          _ -> []
        end
        eligible = Workouts.list_library(user)
          |> Enum.filter(&(Workouts.verify_plan_content(&1) == :ok))
          |> MapSet.new(& &1.id)
        ids = ids |> Enum.filter(&(is_integer(&1) and MapSet.member?(eligible, &1)))
          |> Enum.uniq()
        case recommendation |> Ecto.Changeset.change(ranked_plan_ids: %{"ids" => ids})
               |> Repo.update() do
          {:ok, saved} -> saved
          {:error, _} -> Repo.rollback(Error.new(:invalid_recommendation_selection))
        end
      {:error, error} -> Repo.rollback(error)
    end
  end)
end

def json_schema do
  %{"type" => "object", "additionalProperties" => false,
    "required" => ["action", "workout_plan_id", "definition", "rationale", "ranked_workout_plan_ids"],
    "properties" => %{
      "action" => %{"type" => "string", "enum" => ["select_existing", "create"]},
      "workout_plan_id" => %{"type" => ["integer", "null"]},
      "definition" => %{"anyOf" => [WorkoutDefinition.json_schema(), %{"type" => "null"}]},
      "rationale" => %{"type" => "string"},
      "ranked_workout_plan_ids" => %{"type" => ["array", "null"], "maxItems" => 256,
        "items" => %{"type" => "integer", "minimum" => 1}}}}
end
```

Keep parsing backward-compatible with absent optional order. Compiling eligibility here is off the Home render path. Never bump Home revision for ranking.

In Client add the closed schema selector:

```elixir
defp response_schema(:workout_definition),
  do: {"workout_definition", WorkoutDefinition.json_schema()}
defp response_schema(:coach_recommendation),
  do: {"coach_recommendation", BurpeeTrainer.Coach.Recommendation.json_schema()}
```

Task 5 supplies the full bounded request body. Reconciler changes its one call to:

```elixir
Client.complete(provider_messages(user, slot),
  Keyword.put(provider_options, :response_kind, :coach_recommendation))
```

Its system prompt becomes: `Return one coach proposal: select_existing with workout_plan_id or create with definition, plus rationale. Optionally rank eligible published library IDs in ranked_workout_plan_ids; null means no ranking. Never select a video.` Existing deterministic policy/fallback and expected-selection checks stay intact.

- [ ] **Review gate:** run catalog/client/recommendation/reconciler tests. Keep the provider disabled outside mocks. No new on-mount call, ranking task, or reshuffle trigger.

---

## Task 4: Lossless compiler-faithful grouped inspection

**Files:** create `lib/burpee_trainer/workouts/inspection.ex`; create `test/burpee_trainer/workouts/inspection_test.exs`. Task 8 renders the result. Do not modify the creator's `workout_draft_structure.ex`.

**Contracts:** `Inspection.rows(plan) :: [map()]`; `Inspection.flatten(rows) :: [canonical_program_event]`. Each row has `id`, `kind`, `count`, `units`, `events`, `trailing?`. Equality includes canonical definition and program values, never formatting.

- [ ] **4A red:** actual compiler-backed tests:

```elixir
defmodule BurpeeTrainer.Workouts.InspectionTest do
  use BurpeeTrainer.DataCase, async: true
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Workouts.Inspection

  defp plan(events, duration) do
    reps = Enum.reduce(events, 0, &(&2 + Map.get(&1, "reps", 0)))
    workout_plan_draft_fixture(user_fixture(), %{definition: %{
      "version" => 1, "name" => "Exact inspection", "burpee_type" => "six_count",
      "target_reps" => reps, "target_duration_sec" => duration, "pacing_style" => "even",
      "rationale" => "Compiler fidelity test", "events" => events}})
  end
  defp work(active \\ 5), do: %{"kind" => "work", "reps" => 2,
    "sec_per_rep" => 5, "sec_per_burpee" => active}

  test "identical sets precede invented block grouping" do
    p = plan(List.duplicate(work(), 6), 60)
    assert [%{kind: :repeat, count: 6}] = rows = Inspection.rows(p)
    assert Inspection.flatten(rows) == p.program_json["events"]
  end
  test "terminal active duration and trailing recovery remain exact" do
    p = plan([work(4), work(4)], 19)
    assert length(Inspection.rows(p)) == 2
    p = plan([work(), %{"kind" => "rest", "duration_sec" => 10}], 20)
    assert List.last(Inspection.rows(p)).trailing?
    assert Inspection.flatten(Inspection.rows(p)) == p.program_json["events"]
  end
  test "nonadjacent matching work never merges" do
    b = Map.put(work(), "reps", 3)
    p = plan([work(), b, work()], 35)
    assert length(Inspection.rows(p)) == 3
    repeated = plan([work(), b, work(), b], 50)
    assert [%{count: 2, units: units}] = Inspection.rows(repeated)
    assert length(units) == 4
  end
end
```

- [ ] **4A green:** full pure projection:

```elixir
defmodule BurpeeTrainer.Workouts.Inspection do
  def rows(plan) do
    paired = Enum.zip(plan.definition_json["events"], plan.program_json["events"])
      |> Enum.with_index()
      |> Enum.map(fn {{definition, program}, index} ->
        %{definition: definition, program: program, index: index}
      end)
    last_work = paired |> Enum.filter(&(&1.program["kind"] == "work")) |> List.last()
    {body, trailing} = Enum.split(paired, last_work.index + 1)
    {leading, body} = Enum.split_while(body, &(&1.program["kind"] == "rest"))
    prefix = "home-row-#{plan.id}-#{DateTime.to_unix(plan.updated_at, :microsecond)}"
    Enum.map(leading, &row(prefix, [unit([&1])], 1, false)) ++
      group(prefix, units(body), []) ++
      Enum.map(trailing, &row(prefix, [unit([&1])], 1, true))
  end

  def flatten(rows), do: Enum.flat_map(rows, & &1.events)

  defp units([]), do: []
  defp units([work | rest]) do
    {recovery, remaining} = Enum.split_while(rest, &(&1.program["kind"] == "rest"))
    [unit([work | recovery]) | units(remaining)]
  end
  defp unit(events), do: %{paired: events,
    exact: Enum.map(events, &{&1.definition, &1.program})}

  defp group(_prefix, [], acc), do: Enum.reverse(acc)
  defp group(prefix, units, acc) do
    {width, count} = repeated_prefix(units) || {1, 1}
    {consumed, rest} = Enum.split(units, width * count)
    group(prefix, rest, [row(prefix, consumed, count, false) | acc])
  end
  defp repeated_prefix(units) do
    maximum = div(length(units), 2)
    if maximum > 0 do
      Enum.find_value(1..maximum, fn width ->
        exact = units |> Enum.take(width) |> Enum.map(& &1.exact)
        count = units |> Enum.chunk_every(width, width, :discard)
          |> Enum.take_while(&(Enum.map(&1, fn u -> u.exact end) == exact)) |> length()
        if count >= 2, do: {width, count}
      end)
    end
  end
  defp row(prefix, units, count, trailing?) do
    paired = Enum.flat_map(units, & &1.paired)
    first = hd(paired)
    kind = cond do
      count > 1 -> :repeat
      first.program["kind"] == "rest" -> :recovery
      true -> :set
    end
    %{id: "#{prefix}-#{first.index}", kind: kind, count: count, units: units,
      events: Enum.map(paired, & &1.program), trailing?: trailing?}
  end
end
```

No definition/program writes occur. A final set with different compiled timing or no following inter-set recovery remains distinct; actual trailing recovery is always explicit. Definition size bounds already limit this projection's input.

- [ ] **4B red/green:** add a precision/boundary matrix using valid definitions:

```elixir
test "recovery boundaries are never made uniform" do
  for rests <- [[10, 11], [11, 10], [10, 10]] do
    events = [work(), %{"kind" => "rest", "duration_sec" => hd(rests)},
      work(), %{"kind" => "rest", "duration_sec" => List.last(rests)}]
    p = plan(events, 20 + Enum.sum(rests))
    rows = Inspection.rows(p)
    assert Inspection.flatten(rows) == p.program_json["events"]
    assert List.last(rows).trailing?
    refute Enum.any?(rows, &(&1.kind == :repeat))
  end
end
```

- [ ] **Review gate:** run inspection and existing compiler/workout-definition/program-hash tests. Rendering must label prescribed cadence, not measured pace.

---

## Task 5: Stable, private, append-only design contexts and request bounds

**Files:** create `lib/burpee_trainer/coach/{design_session,design_entry,context,setting,workout_memory,memory}.ex`; modify `workouts/workout_plan.ex`, `workouts.ex`, `coach/client.ex`; migration `add_workout_design_context`; new `test/burpee_trainer/coach/context_test.exs`, extend `client_test.exs`.

**Contracts:** `Context.ensure_session(user, source_or_nil, server_workspace_key)` returns one owned context; `append(user, session_id, attempt_uuid, kind, payload)` inserts only; `entries(user, session_id)` returns all ordered entries; `messages(user, session_id, source_or_nil, active_attempt_uuid, system_prompt)` returns full messages or a safe error. All return `{:ok, value} | {:error, Error.t()}`. `Context.check_source/3` and `check_home_workspace/3` return `:ok | {:error, Error.t()}`. `Memory.global_context/1` returns actual persisted settings/memories.

### Identity and privacy invariant

Unique `(user_id, workspace_key)` is the smallest stable association for failed published-source requests: no draft is needed to locate the log. The first initializer atomically inserts the context plus initial context/baseline; concurrent losers load it. Source provenance must match on reuse. Published rows are never changed. Home reload derives the same key from its persisted reviewed revision. Successful drafts carry `design_session_id`, so subsequent mutable-draft edits continue the same log. Independently selecting a published plan increments Home revision and creates a different writable workspace. Imported prior owned history is a full immutable value, not a pointer to a shared writable session. A foreign/shared source's private log is never queried.

- [ ] **5A red:** full identity/privacy tests; use these imports/aliases in the new test module.

```elixir
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
    {:ok, _} = Context.append(user, a.id, attempt, :outcome,
      %{"status" => "failed", "code" => "provider_timeout"})
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
    {:ok, _} = Context.append(owner, private.id, Ecto.UUID.generate(), :instruction,
      %{"text" => "private-author-instruction"})
    # Assemble the shared fixture before publication; never mutate an immutable source.
    fields = [:name, :request_text, :definition_json, :program_json, :content_hash,
      :burpee_type, :target_reps, :target_duration_sec]
    shared = %BurpeeTrainer.Workouts.WorkoutPlan{user_id: nil, origin: :built_in,
      state: :draft, design_session_id: private.id}
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
    {:ok, [_, _, message]} = Context.messages(user, s.id, source, a, "Contract")
    body = Jason.decode!(message.content)
    assert body["active_attempt"]["id"] == a
    assert body["active_attempt"]["instruction"] == "Six-counts"
    assert Enum.any?(body["entries"], &(&1["attempt_id"] == b))
  end
end
```

The shared-source fixture below is assembled before publication, within the test sandbox. It deliberately carries the other author's design-session identity and request text; the new context must neither read nor copy those private fields.

- [ ] **5A green:** migration:

```elixir
def change do
  create table(:workout_design_sessions) do
    add :user_id, references(:users, on_delete: :delete_all), null: false
    add :workspace_key, :string, null: false
    add :source_plan_id, :integer
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
  create unique_index(:workout_design_sessions, [:user_id, :workspace_key])
  create table(:workout_design_entries) do
    add :design_session_id, references(:workout_design_sessions, on_delete: :delete_all), null: false
    add :attempt_id, :uuid, null: false
    add :kind, :string, null: false
    add :payload, :map, null: false
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
  create index(:workout_design_entries, [:design_session_id, :id])
  create unique_index(:workout_design_entries, [:design_session_id, :attempt_id, :kind])
  alter table(:workout_plans) do
    add :design_session_id, references(:workout_design_sessions, on_delete: :nilify_all)
  end
  create table(:coach_settings) do
    add :user_id, references(:users, on_delete: :delete_all), null: false
    add :settings, :map, null: false, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
  create unique_index(:coach_settings, [:user_id])
  create table(:coach_workout_memories) do
    add :user_id, references(:users, on_delete: :delete_all), null: false
    add :workout_plan_id, :integer, null: false
    add :design_session_id, :integer
    add :facts, :map, null: false
    add :workout_reason, :map, null: false
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
  create unique_index(:coach_workout_memories, [:user_id, :workout_plan_id])
  execute("""
  CREATE TRIGGER workout_design_entries_no_update
  BEFORE UPDATE ON workout_design_entries
  BEGIN SELECT RAISE(ABORT, 'design_entries_append_only'); END
  """, "DROP TRIGGER workout_design_entries_no_update")
end
```

Entry deletion remains available only through authorized context/user cleanup, not an application entry API. Draft deletion cannot delete the context: `source_plan_id` is retained provenance, not a cascading draft FK. Do not edit old immutable-plan triggers.

One module per named file:

```elixir
# lib/burpee_trainer/coach/design_session.ex
defmodule BurpeeTrainer.Coach.DesignSession do
  use Ecto.Schema
  @type t :: %__MODULE__{}
  schema "workout_design_sessions" do
    field :user_id, :integer
    field :workspace_key, :string
    field :source_plan_id, :integer
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
```

```elixir
# lib/burpee_trainer/coach/design_entry.ex
defmodule BurpeeTrainer.Coach.DesignEntry do
  use Ecto.Schema
  @type t :: %__MODULE__{}
  schema "workout_design_entries" do
    field :design_session_id, :integer
    field :attempt_id, Ecto.UUID
    field :kind, Ecto.Enum, values: [:initial_context, :baseline, :instruction, :proposal, :outcome]
    field :payload, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
```

```elixir
# lib/burpee_trainer/coach/setting.ex
defmodule BurpeeTrainer.Coach.Setting do
  use Ecto.Schema
  schema "coach_settings" do
    field :user_id, :integer
    field :settings, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
end
```

```elixir
# lib/burpee_trainer/coach/workout_memory.ex
defmodule BurpeeTrainer.Coach.WorkoutMemory do
  use Ecto.Schema
  schema "coach_workout_memories" do
    field :user_id, :integer
    field :workout_plan_id, :integer
    field :design_session_id, :integer
    field :facts, :map
    field :workout_reason, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
```

In `WorkoutPlan.schema`: `field :design_session_id, :integer`. Add `:design_session_id` to Workouts' `@draft_revision_fields`, **not** the provider/browser cast fields. Task 6 assigns it programmatically. Existing changesets preserve it on replacement.

Create `Memory` with this real reader; Task 7 adds its writer:

```elixir
defmodule BurpeeTrainer.Coach.Memory do
  import Ecto.Query
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Coach.{Setting, WorkoutMemory}
  def global_context(user) do
    settings = case Repo.get_by(Setting, user_id: user.id) do
      nil -> %{}
      row -> row.settings
    end
    memories = Repo.all(from m in WorkoutMemory, where: m.user_id == ^user.id,
      order_by: [asc: m.id])
    %{settings: settings, workout_memories: Enum.map(memories, fn m ->
      %{workout_plan_id: m.workout_plan_id, design_session_id: m.design_session_id,
        facts: m.facts, workout_reason: m.workout_reason}
    end)}
  end
end
```

Full `Context` implementation:

```elixir
defmodule BurpeeTrainer.Coach.Context do
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Coach.{DesignSession, DesignEntry, Memory}
  alias BurpeeTrainer.Workouts.Error
  @kinds [:initial_context, :baseline, :instruction, :proposal, :outcome]

  def home_key(expected),
    do: "home:#{expected.recommendation_id}:#{expected.home_revision}"

  def ensure_session(user, source, key) do
    safe(fn ->
      with :ok <- authorized_source(user, source) do
        if source && source.state == :draft && source.design_session_id do
          owned_session(user, source.design_session_id)
        else
          key = if source && source.state == :draft, do: "draft:#{source.id}", else: key
          initialize(user, source, key)
        end
      end
    end)
  end

  defp initialize(user, source, key) when is_binary(key) and byte_size(key) in 1..200 do
    Repo.immediate_transaction(fn ->
      now = DateTime.utc_now()
      source_id = source && source.id
      {inserted, _} = Repo.insert_all(DesignSession,
        [%{user_id: user.id, workspace_key: key, source_plan_id: source_id, inserted_at: now}],
        on_conflict: :nothing, conflict_target: [:user_id, :workspace_key])
      session = Repo.get_by!(DesignSession, user_id: user.id, workspace_key: key)
      if session.source_plan_id != source_id,
        do: Repo.rollback(Error.new(:design_workspace_changed))
      if inserted == 1 do
        attempt = Ecto.UUID.generate()
        insert_or_rollback(user, session.id, attempt, :initial_context,
          %{"global_context" => Memory.global_context(user)})
        insert_or_rollback(user, session.id, attempt, :baseline, baseline(user, source))
      end
      session
    end)
  end
  defp initialize(_user, _source, _key), do: {:error, Error.new(:design_workspace_changed)}

  def append(user, session_id, attempt, kind, payload) do
    safe(fn ->
      with {:ok, _} <- owned_session(user, session_id),
           {:ok, ^attempt} <- Ecto.UUID.cast(attempt),
           true <- kind in @kinds and is_map(payload) do
        %DesignEntry{design_session_id: session_id, attempt_id: attempt,
          kind: kind, payload: payload}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint([:design_session_id, :attempt_id, :kind])
        |> Repo.insert()
        |> case do
          {:ok, entry} -> {:ok, entry}
          {:error, _} -> {:error, Error.new(:design_log_failed)}
        end
      else
        {:error, %Error{} = error} -> {:error, error}
        _ -> {:error, Error.new(:design_log_failed)}
      end
    end)
  end

  def entries(user, session_id) do
    safe(fn ->
      with {:ok, _} <- owned_session(user, session_id) do
        {:ok, Repo.all(from e in DesignEntry, where: e.design_session_id == ^session_id,
          order_by: [asc: e.id])}
      end
    end)
  end

  def messages(user, session_id, source, attempt, prompt) do
    safe(fn ->
      with :ok <- check_source(user, session_id, source),
           {:ok, entries} <- entries(user, session_id),
           %DesignEntry{} = active <- Enum.find(entries,
             &(&1.attempt_id == attempt and &1.kind == :instruction)) do
        messages = [
          %{role: "system", content: prompt},
          %{role: "system", content: Jason.encode!(%{scope: "global",
            context: Memory.global_context(user),
            rule: "Local workout instructions are not enduring global preferences."})},
          %{role: "user", content: Jason.encode!(%{scope: "workout_design",
            active_attempt: %{id: attempt, instruction: active.payload["text"]},
            rule: "Revise only for active_attempt; other attempts are historical context.",
            current_definition: source && source.definition_json,
            entries: Enum.map(entries, &entry_payload/1)})}
        ]
        if byte_size(Jason.encode!(messages)) <= 262_144,
          do: {:ok, messages}, else: {:error, Error.new(:authoring_context_too_large)}
      else
        {:error, %Error{} = error} -> {:error, error}
        _ -> {:error, Error.new(:design_attempt_not_found)}
      end
    end)
  end

  def check_source(user, id, source) do
    with {:ok, session} <- owned_session(user, id) do
      valid = cond do
        source == nil -> session.source_plan_id == nil
        source.state == :draft and source.user_id == user.id and
          source.design_session_id == id -> true
        true -> session.source_plan_id == source.id
      end
      if valid, do: :ok, else: {:error, Error.new(:design_workspace_changed)}
    end
  end

  def check_home_workspace(user, id, expected) do
    with :ok <- check_source(user, id, expected.plan),
         {:ok, session} <- owned_session(user, id) do
      if expected.plan.state == :draft or session.workspace_key == home_key(expected),
        do: :ok, else: {:error, Error.new(:design_workspace_changed)}
    end
  end

  defp owned_session(user, id) do
    case Repo.get_by(DesignSession, id: id, user_id: user.id) do
      nil -> {:error, Error.new(:design_session_not_owned)}
      session -> {:ok, session}
    end
  end
  defp authorized_source(_user, nil), do: :ok
  defp authorized_source(user, source) do
    with {:ok, current} <- Workouts.design_source(user, source.id),
         true <- current.updated_at == source.updated_at and
           current.content_hash == source.content_hash do
      :ok
    else
      _ -> {:error, Error.new(:source_unavailable)}
    end
  end
  defp baseline(_user, nil), do: %{"imported" => true, "source" => nil}
  defp baseline(user, source) do
    public = %{"imported" => true, "source_plan_id" => source.id,
      "definition" => source.definition_json, "program" => source.program_json}
    if source.user_id == user.id do
      prior = case source.design_session_id do
        nil -> []
        id ->
          case entries(user, id) do
            {:ok, values} -> Enum.map(values, &entry_payload/1)
            {:error, error} -> Repo.rollback(error)
          end
      end
      Map.merge(public, %{"request_text" => source.request_text,
        "prior_owned_entries" => prior})
    else
      public
    end
  end
  defp entry_payload(e), do: %{id: e.id, attempt_id: e.attempt_id,
    kind: Atom.to_string(e.kind), payload: e.payload}
  defp insert_or_rollback(user, id, attempt, kind, payload) do
    case append(user, id, attempt, kind, payload) do
      {:ok, entry} -> entry
      {:error, error} -> Repo.rollback(error)
    end
  end
  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, Error.new(:design_context_unavailable)}
  catch
    :exit, _ -> {:error, Error.new(:design_context_unavailable)}
  end
end
```

`messages/5` returns all rows from one query snapshot, including other attempts, with a separately identified active instruction. It does not crop at the active row or silently omit concurrent history. Imported owned history remains complete; overflow fails explicitly.

- [ ] **5B red/green:** prove concurrent initialization, using supervised tasks and the existing repository sandbox ownership pattern. This is an actual runnable test in the context module:

```elixir
test "concurrent initializers produce one context and one initial baseline" do
  user = user_fixture()
  source = plan_fixture(user)
  parent = self()
  supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.InitializerTasks})
  tasks = for _ <- 1..2 do
    Task.Supervisor.async_nolink(supervisor, fn ->
      send(parent, {:ready, self()})
      receive do :go -> Context.ensure_session(user, source, "home:40:1") end
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
```

The shared sandbox serializes SQL access; this test exercises concurrent initialization calls and the unique-row/one-baseline invariant. Independent-browser concurrency is also required in Task 10's disposable database.

- [ ] **5C red:** Client overflow test, no network:

```elixir
test "oversized serialized request fails before HTTP" do
  parent = self()
  req = Req.new(adapter: fn request ->
    send(parent, :unexpected_http)
    {request, %Req.Response{status: 500, body: ""}}
  end)
  assert {:error, %Error{code: :authoring_context_too_large}} = Client.complete(
    [%{role: "user", content: String.duplicate("x", 262_145)}], req: req,
    config: [enabled: true, url: "https://provider.test/v1", api_key: "test", model: "test"])
  refute_received :unexpected_http
end
```

- [ ] **5C green:** in Client add this request builder; in `complete_with_config/3`, after loading model and before `Req.post`, add `{:ok, encoded} <- encode_request(messages, model, opts)`. Replace its existing `json:` option with `body: encoded` and `headers: [{"content-type", "application/json"}]`. Keep all current HTTP timeout/redirect/retry/response bound options. Add `{:error, %Error{} = error} -> {:error, error}` **before** the generic error branch.

```elixir
defp encode_request(messages, model, opts) do
  {name, schema} = response_schema(Keyword.get(opts, :response_kind, :workout_definition))
  body = %{model: model, max_tokens: @max_output_tokens, temperature: 0,
    response_format: %{type: "json_schema", json_schema: %{name: name, strict: true, schema: schema}},
    messages: messages}
  encoded = Jason.encode!(body)
  if byte_size(encoded) <= 262_144, do: {:ok, encoded},
    else: {:error, Error.new(:authoring_context_too_large)}
end
```

The preliminary messages bound cannot replace the final full-envelope bound. Preserve response limit 262,144, output token limit 16,384, 500-grapheme/4,000-byte instruction limits, unique JSON key rejection, one HTTP request, and no repairs.

- [ ] **Review gate:** run context/client tests and `MIX_ENV=test mix run --no-start scripts/migrations/rehearse_deletion_first.exs`. No compiler/provider call is inside context initialization transactions.

---

## Task 6: One-call revisions with complete safe outcome handling

**Files:** modify `lib/burpee_trainer/coach.ex`, `lib/burpee_trainer/workouts.ex`, `lib/burpee_trainer/coach_reconciler.ex`; narrowly extend creator UUID plumbing in `lib/burpee_trainer_web/live/workout_creation_live.ex`; extend `test/burpee_trainer/coach/draft_authoring_test.exs` and Task 1/5 tests.

**Contracts:** `Coach.revise_home_workout(user, expected, instruction, opts \\ [])` returns `HomeSelection`; existing `create_draft/3`, `refine_draft/4` still return a draft. `Workouts.commit_home_revision/6` and `commit_authored_revision/6` are atomic persistence boundaries, never HTTP boundaries.

- [ ] **6A red:** add actual published-failure/reload, exception, context-overflow, and stale-result tests to existing `draft_authoring_test.exs`. Its existing `definition/4`, `request/2`, `opts/1`, `provider_definition/2`, `request_count/1`, and `raw_row/1` helpers remain available. Add `alias BurpeeTrainer.Coach.{Context, DesignEntry}` and this fixture helper:

```elixir
defp shown_workout(user) do
  {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
  {:ok, slot} = BurpeeTrainer.Coach.Policy.required_slot(user, DateTime.utc_now(:second))
  {:ok, shown} = Workouts.ensure_home_selection(user, slot)
  {user, slot, shown}
end

test "failed published revision retains history through reload", %{counter: counter} do
  {user, slot, initial} = shown_workout(user_fixture())
  source = plan_fixture(user, %{burpee_type: "navy_seal"})
  {:ok, shown} = Workouts.select_home_workout(user, initial, source.id)
  before = raw_row(source.id)
  req = request(counter, &Plug.Conn.send_resp(&1, 503, "private response"))
  assert {:error, %Error{code: :provider_unavailable}} =
    Coach.revise_home_workout(user, shown, "Less rest", opts(req))
  assert Workouts.list_drafts(user) == []
  {:ok, reopened} = Workouts.ensure_home_selection(user, slot)
  {:ok, session} = Context.ensure_session(user, source, Context.home_key(reopened))
  {:ok, entries} = Context.entries(user, session.id)
  assert Enum.any?(entries, &(&1.kind == :instruction and &1.payload["text"] == "Less rest"))
  assert Enum.any?(entries, &(&1.kind == :outcome and &1.payload["status"] == "failed"))
  req = request(counter, &provider_definition(&1, definition("Six-count revision", "six_count", 100, 1200)))
  assert {:ok, revised} = Coach.revise_home_workout(user, reopened, "Use six-counts", opts(req))
  assert revised.plan.design_session_id == session.id
  assert revised.plan.id != source.id
  assert revised.plan.burpee_type == :six_count
  assert raw_row(source.id) == before
  assert request_count(counter) == 2
end

test "message overflow records a failure without HTTP", %{counter: counter} do
  {user, _slot, shown} = shown_workout(user_fixture())
  {:ok, context} = Context.ensure_session(user, shown.plan, Context.home_key(shown))
  for _ <- 1..530 do
    {:ok, _} = Context.append(user, context.id, Ecto.UUID.generate(), :instruction,
      %{"text" => String.duplicate("x", 500)})
  end
  req = request(counter, &provider_definition(&1, definition("Unused")))
  assert {:error, %Error{code: :authoring_context_too_large}} =
    Coach.revise_home_workout(user, shown, "Try once", opts(req))
  assert request_count(counter) == 0
  {:ok, entries} = Context.entries(user, context.id)
  assert List.last(entries).payload["code"] == "authoring_context_too_large"
end

test "provider exception is caught and receives a safe outcome", %{counter: counter} do
  {user, _slot, shown} = shown_workout(user_fixture())
  req = request(counter, fn _conn -> raise "private exception text" end)
  assert {:error, %Error{code: :provider_unavailable}} =
    Coach.revise_home_workout(user, shown, "Change it", opts(req))
  {:ok, context} = Context.ensure_session(user, shown.plan, Context.home_key(shown))
  {:ok, entries} = Context.entries(user, context.id)
  outcome = List.last(entries)
  assert outcome.kind == :outcome
  assert outcome.payload == %{"status" => "failed", "code" => "provider_unavailable"}
end

test "selection changed during HTTP creates no orphan", %{counter: counter} do
  {user, _slot, shown} = shown_workout(user_fixture())
  alternative = plan_fixture(user)
  req = request(counter, fn conn ->
    {:ok, _} = Workouts.select_home_workout(user, shown, alternative.id)
    provider_definition(conn, definition("Must not persist"))
  end)
  assert {:error, %Error{code: :home_selection_changed}} =
    Coach.revise_home_workout(user, shown, "Revise", opts(req))
  assert Workouts.list_drafts(user) == []
  assert request_count(counter) == 1
end
```

- [ ] **6A green:** add `alias BurpeeTrainer.Coach.Context` to Coach. Replace the public authoring bodies with these definitions while keeping existing validators, `refinable_draft/2`, prompt, and safe create diagnostic helpers. This code—not an instruction in prose—routes **every post-instruction result or catchable exception** through failure recording. Failure recording cannot replace the original error.

```elixir
def revise_home_workout(user, expected, instruction, opts \\ []) do
  with :ok <- outside_authoring_transaction(),
       {:ok, text} <- validate_authoring_input(instruction),
       {:ok, source} <- Workouts.verify_home_selection(user, expected),
       {:ok, context} <- Context.ensure_session(user, source, Context.home_key(expected)) do
    author_attempt(user, source, context, text, opts, fn definition, attempt ->
      Workouts.commit_home_revision(user, expected, definition, text, context.id, attempt)
    end)
  end
end

def create_draft(user, request, opts \\ [])
def create_draft(%Accounts.User{} = user, request, opts) when is_binary(request) and is_list(opts) do
  started_at = System.monotonic_time()
  result = with :ok <- outside_authoring_transaction(),
                {:ok, text} <- validate_authoring_input(request),
                key <- Keyword.get(opts, :workspace_key, "creator:#{Ecto.UUID.generate()}"),
                {:ok, context} <- Context.ensure_session(user, nil, key) do
    author_attempt(user, nil, context, text, opts, fn definition, attempt ->
      Workouts.commit_authored_revision(user, nil, definition, text, context.id, attempt)
    end)
  end
  log_create_failure(result, started_at)
end

def create_draft(%Accounts.User{}, _request, _opts),
  do: {:error, Error.new(:invalid_workout_definition)}

def refine_draft(user, id, instruction, opts \\ [])
def refine_draft(%Accounts.User{} = user, id, instruction, opts)
    when is_integer(id) and id > 0 and is_binary(instruction) and is_list(opts) do
  with :ok <- outside_authoring_transaction(),
       {:ok, draft} <- refinable_draft(user, id),
       {:ok, text} <- validate_authoring_input(instruction),
       {:ok, context} <- Context.ensure_session(user, draft, "draft:#{draft.id}") do
    author_attempt(user, draft, context, text, opts, fn definition, attempt ->
      Workouts.commit_authored_revision(user, draft, definition, text, context.id, attempt)
    end)
  end
end

def refine_draft(%Accounts.User{}, id, _instruction, _opts),
  do: {:error, Error.new(:draft_not_found, %{draft_id: id})}

defp author_attempt(user, source, context, text, opts, commit) do
  attempt = Ecto.UUID.generate()
  with {:ok, _} <- Context.append(user, context.id, attempt, :instruction, %{"text" => text}) do
    result = safe_authoring(fn ->
      with {:ok, messages} <- Context.messages(user, context.id, source, attempt,
             @authoring_system_prompt),
           {:ok, proposal} <- Client.complete(messages,
             Keyword.put(opts, :response_kind, :workout_definition)),
           {:ok, _} <- Context.append(user, context.id, attempt, :proposal,
             %{"definition" => proposal}),
           {:ok, definition} <- validate_provider_definition(proposal) do
        commit.(WorkoutDefinition.canonical_map(definition), attempt)
      end
    end)
    record_failed_outcome(user, context.id, attempt, result)
  end
end

defp outside_authoring_transaction do
  if BurpeeTrainer.Repo.in_transaction?(),
    do: {:error, Error.new(:authoring_transaction_forbidden)}, else: :ok
end

defp safe_authoring(fun) do
  fun.()
rescue
  _ -> {:error, Error.new(:provider_unavailable)}
catch
  :exit, _ -> {:error, Error.new(:provider_unavailable)}
  :throw, _ -> {:error, Error.new(:provider_unavailable)}
end

defp record_failed_outcome(user, id, attempt, {:error, %Error{} = error} = original) do
  recorded = try do
    Context.append(user, id, attempt, :outcome,
      %{"status" => "failed", "code" => Atom.to_string(error.code)})
  rescue
    _ -> {:error, :log_unavailable}
  catch
    _, _ -> {:error, :log_unavailable}
  end
  if not match?({:ok, _}, recorded),
    do: Logger.warning("workout_design_failure_outcome_unavailable")
  original
end

defp record_failed_outcome(_user, _id, _attempt, result), do: result
```

Both persistence contracts take six arguments: user, source/selection, definition, text, context ID, attempt UUID. Provider options belong only to Coach.

Uncatchable VM/process termination may leave an instruction without a terminal outcome; do not fabricate completion or add durable recovery machinery. A database failure can prevent outcome insertion; emit a safe diagnostic and return the original error. This is not permission to swallow ordinary message/provider/validation failures without attempting to record them.

- [ ] **6B red:** test accepted content/log/pointer atomicity and log-failure error preservation:

```elixir
test "failure-log failure does not replace the provider error", %{counter: counter} do
  {user, _slot, shown} = shown_workout(user_fixture())
  {:ok, context} = Context.ensure_session(user, shown.plan, Context.home_key(shown))
  req = request(counter, fn conn ->
    # Simulates loss of the log store after the instruction was persisted.
    Repo.delete_all(from e in DesignEntry, where: e.design_session_id == ^context.id)
    Repo.delete_all(from s in BurpeeTrainer.Coach.DesignSession, where: s.id == ^context.id)
    Req.Test.transport_error(conn, :timeout)
  end)
  assert {:error, %Error{code: :provider_timeout}} =
    Coach.revise_home_workout(user, shown, "Try", opts(req))
end
```

- [ ] **6B green:** complete Workouts persistence code (with `alias BurpeeTrainer.Coach.Context`). All referenced lifecycle helpers already exist. The nested authoring commit rolls back with the outer Home pointer transaction.

```elixir
def commit_home_revision(user, expected, definition, text, context_id, attempt) do
  immediate_lifecycle_transaction(fn ->
    with {:ok, r} <- home_recommendation(user, expected),
         {:ok, source} <- verify_home_selection(user, expected),
         :ok <- Context.check_home_workspace(user, context_id, expected),
         {:ok, draft} <- commit_authored_revision(user, source, definition, text,
           context_id, attempt),
         {:ok, changed} <- write_home_pointer(r, draft.id) do
      {:ok, HomeSelection.new(changed, draft)}
    end
  end)
end

def commit_authored_revision(user, expected, definition, text, context_id, attempt) do
  immediate_lifecycle_transaction(fn ->
    with :ok <- Context.check_source(user, context_id, expected),
         {:ok, source} <- current_authoring_source(user, expected),
         {:ok, content} <- canonical_draft_content(%{definition: definition, request_text: text}),
         {:ok, draft} <- save_authored_draft(user, source, content, context_id),
         {:ok, _} <- Context.append(user, context_id, attempt, :outcome,
           %{"status" => "accepted", "workout_plan_id" => draft.id,
             "content_hash" => draft.content_hash,
             "updated_at" => DateTime.to_iso8601(draft.updated_at)}) do
      {:ok, draft}
    end
  end)
end

defp current_authoring_source(_user, nil), do: {:ok, nil}
defp current_authoring_source(user, expected) do
  with {:ok, source} <- home_plan(user, expected.id),
       :ok <- compare_expected_draft_revision(source, %{expected_revision: expected}),
       :ok <- verify_stored_draft(source) do
    {:ok, source}
  end
end

defp save_authored_draft(_user, %{state: :draft} = source, content, context_id) do
  source |> WorkoutPlan.replace_draft_changeset(content)
    |> Ecto.Changeset.put_change(:design_session_id, context_id)
    |> Repo.update() |> normalize_plan_write()
end

defp save_authored_draft(user, _published_or_nil, content, context_id) do
  %WorkoutPlan{user_id: user.id, origin: :user, state: :draft, design_session_id: context_id}
  |> WorkoutPlan.new_draft_changeset(content) |> Repo.insert() |> normalize_plan_write()
end
```

No eager `copy_to_draft/2`, copy-name suffix, published-source mutation, or automatic slot type/duration policy is used for explicit revisions.

Creator integration is only stable identity plumbing: add `design_workspace_key: "creator:#{Ecto.UUID.generate()}"` to mount assigns; in `generate`, capture `workspace_key = socket.assigns.design_workspace_key` before the closure and change its nil-draft branch to:

```elixir
Coach.create_draft(user, request, workspace_key: workspace_key)
```

Keep that assign on failure; do not regenerate it in `handle_async`. Existing refinement/review/Start UX remains intact. A direct `Coach.create_draft/3` call without a key deliberately allocates a new independent workspace; the interactive creator always supplies its retained key.

- [ ] **6C red/green:** automatic proposal context must not be stateless. Add this production boundary to Coach; replace the reconciler's current `Client.complete`/`Recommendation.apply_proposal` pair with its single call. It logs the exact original slot/library prompt inside the active instruction payload and uses the recommendation response schema, still one request.

```elixir
def recommend_workout(user, recommendation, original_messages, opts) do
  key = "recommendation:#{recommendation.id}:#{recommendation.selected_workout_plan_id}"
  with :ok <- outside_authoring_transaction(),
       {:ok, context} <- Context.ensure_session(user, nil, key) do
    attempt = Ecto.UUID.generate()
    with {:ok, _} <- Context.append(user, context.id, attempt, :instruction,
           %{"text" => "Choose the next workout for this slot.",
             "request_messages" => original_messages}) do
      result = safe_authoring(fn ->
        with {:ok, messages} <- Context.messages(user, context.id, nil, attempt,
               "Return the coach recommendation schema; use the active attempt's slot and library facts."),
             {:ok, response} <- Client.complete(messages,
               Keyword.put(opts, :response_kind, :coach_recommendation)),
             {:ok, _} <- Context.append(user, context.id, attempt, :proposal, response) do
          BurpeeTrainer.Repo.immediate_transaction(fn ->
            expected = {:plan, recommendation.selected_workout_plan_id}
            with {:ok, changed} <- BurpeeTrainer.Coach.Recommendation.apply_proposal(
                   user, recommendation.id, response, expected),
                 :ok <- link_recommendation_context(user, changed, context.id),
                 {:ok, _} <- Context.append(user, context.id, attempt, :outcome,
                   %{"status" => "accepted", "pending_draft_id" => changed.pending_draft_id,
                     "selected_plan_id" => changed.selected_workout_plan_id}) do
              changed
            else
              {:error, error} -> BurpeeTrainer.Repo.rollback(error)
            end
          end)
        end
      end)
      record_failed_outcome(user, context.id, attempt, result)
    end
  end
end

defp link_recommendation_context(_user, %{pending_draft_id: nil}, _id), do: :ok
defp link_recommendation_context(user, recommendation, id) do
  with {:ok, draft} <- Workouts.get_draft(user, recommendation.pending_draft_id),
       :ok <- Context.check_source(user, id, nil) do
    case draft |> Ecto.Changeset.change(design_session_id: id) |> BurpeeTrainer.Repo.update() do
      {:ok, _} -> :ok
      {:error, _} -> {:error, Error.new(:design_log_failed)}
    end
  end
end
```

Reconciler call:

```elixir
BurpeeTrainer.Coach.recommend_workout(user, recommendation,
  provider_messages(user, slot), provider_options)
```

Remove only aliases made unused by that call replacement. Existing policy/fallback and no-overwrite Home pointer remain unchanged. Extend the reconciler's existing mock-response tests to assert the persisted pending draft has an owned `design_session_id` and `Context.entries/2` contains instruction/proposal/accepted outcome. Existing `Client` mocks must expect three messages/full context instead of two bare messages.

- [ ] **Review gate:** run draft_authoring/context/home_selection/reconciler and existing creator tests. Retain original 500-grapheme, 4,000-byte, invalid schema/program, source immutability, concurrency, and ABA tests. No HTTP occurs in any persistence transaction.

---

## Task 7: Post-commit best-effort memory, never delivery infrastructure

**Files:** extend `lib/burpee_trainer/coach/memory.ex`; create `memory_subscriber.ex`; modify `application.ex` and public publication wrappers in `workouts.ex`; new `test/burpee_trainer/{coach/memory_subscriber,workouts/finalization}_test.exs`.

**Contracts:** `Memory.record_finalized_workout(user_id, plan_id, design_session_id) :: :ok | {:error, term()}`. Event is `{:workout_finalized, %{user_id: ..., workout_plan_id: ..., design_session_id: ...}}` on `"workout_finalized"`. No prompts in the event.

- [ ] **7A red:** exact rollback/no-event and memory-scope tests:

```elixir
test "enclosing rollback emits no finalization event" do
  user = user_fixture()
  draft = workout_plan_draft_fixture(user)
  Phoenix.PubSub.subscribe(BurpeeTrainer.PubSub, "workout_finalized")
  assert {:error, :forced} = Repo.transaction(fn ->
    assert {:ok, _} = Workouts.publish_draft(user, draft.id)
    Repo.rollback(:forced)
  end)
  refute_received {:workout_finalized, _}
  assert {:ok, %{state: :draft}} = Workouts.get_draft(user, draft.id)
end

test "memory stores scoped facts and does not alter global settings" do
  user = user_fixture()
  plan = plan_fixture(user, %{request_text: "Less rest in this workout"})
  assert :ok = Memory.record_finalized_workout(user.id, plan.id, nil)
  assert :ok = Memory.record_finalized_workout(user.id, plan.id, nil)
  context = Memory.global_context(user)
  assert context.settings == %{}
  assert [memory] = context.workout_memories
  assert memory.facts["content_hash"] == plan.content_hash
  assert memory.workout_reason["scope"] == "workout"
end
```

Use `DataCase`, fixture imports, and aliases `Repo`, `Workouts`, `Memory` in these test files; they are existing modules.

- [ ] **7A green:** add to Memory, with `alias BurpeeTrainer.{Accounts, Workouts}` and `alias BurpeeTrainer.Coach.Context`:

```elixir
def record_finalized_workout(user_id, plan_id, design_session_id) do
  with %Accounts.User{} = user <- Accounts.get_user(user_id),
       %Workouts.WorkoutPlan{user_id: ^user_id, state: state} = plan <-
         Repo.get(Workouts.WorkoutPlan, plan_id),
       true <- state in [:published, :archived] and plan.design_session_id == design_session_id,
       {:ok, entries} <- memory_entries(user, design_session_id) do
    attempts = entries |> Enum.filter(fn e ->
      e.kind == :outcome and e.payload["status"] == "accepted" and
        (e.payload["workout_plan_id"] == plan.id or e.payload["pending_draft_id"] == plan.id)
    end) |> MapSet.new(& &1.attempt_id)
    instructions = entries |> Enum.filter(&(&1.kind == :instruction and
      MapSet.member?(attempts, &1.attempt_id))) |> Enum.map(& &1.payload["text"])
    row = %{user_id: user.id, workout_plan_id: plan.id, design_session_id: design_session_id,
      facts: %{burpee_type: Atom.to_string(plan.burpee_type), reps: plan.target_reps,
        duration_sec: plan.target_duration_sec, content_hash: plan.content_hash},
      workout_reason: %{scope: "workout", rationale: plan.definition_json["rationale"],
        accepted_instructions: instructions}, inserted_at: DateTime.utc_now()}
    Repo.insert_all(WorkoutMemory, [row], on_conflict: :nothing,
      conflict_target: [:user_id, :workout_plan_id])
    :ok
  else
    _ -> {:error, :unavailable_finalized_workout}
  end
rescue
  _ -> {:error, :memory_unavailable}
end

defp memory_entries(_user, nil), do: {:ok, []}
defp memory_entries(user, id), do: Context.entries(user, id)
```

Publication wrappers: retain the existing `accept_candidate/4` transaction body, mechanically rename its two public clauses to private `accept_candidate_without_notification/4`, and add this public wrapper (keep the original public spec):

```elixir
def accept_candidate(user, recommendation_id, draft_id, expected_selection) do
  case accept_candidate_without_notification(user, recommendation_id, draft_id, expected_selection) do
    {:ok, recommendation} ->
      case get_library_plan(user, draft_id) do
        {:ok, plan} -> BurpeeTrainer.Workouts.Finalization.notify(plan)
        _ -> :ok
      end
      {:ok, recommendation}
    error -> error
  end
end
```

Replace valid-ID `publish_draft/2` body only:

```elixir
def publish_draft(%User{} = user, id) when is_integer(id) and id > 0 do
  case immediate_lifecycle_transaction(fn -> publish_unattached_draft(user, id) end) do
    {:ok, plan} ->
      BurpeeTrainer.Workouts.Finalization.notify(plan)
      {:ok, plan}
    error -> error
  end
end
```

Task 2's outer Start already uses `Finalization.deliver/1`; nested acceptance emits nothing while `Repo.in_transaction?()`. Duplicate Start, existing published Start, rolled-back transaction, and video selection do not emit a finalization event. An externally enclosing transaction can suppress an otherwise valid event entirely; that is acceptable best effort, unlike premature notification.

- [ ] **7B red/green:** subscriber implementation and deterministic message-driven test:

```elixir
defmodule BurpeeTrainer.Coach.MemorySubscriber do
  use GenServer
  alias BurpeeTrainer.Coach.Memory
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts,
    name: Keyword.get(opts, :name, __MODULE__))
  def init(opts) do
    Phoenix.PubSub.subscribe(BurpeeTrainer.PubSub, "workout_finalized")
    {:ok, %{tasks: Keyword.get(opts, :task_supervisor, BurpeeTrainer.CoachMemoryTaskSupervisor),
      record: Keyword.get(opts, :record, &Memory.record_finalized_workout/3)}}
  end
  def handle_info({:workout_finalized, ids}, state) do
    Task.Supervisor.start_child(state.tasks, fn ->
      try do
        state.record.(ids.user_id, ids.workout_plan_id, ids.design_session_id)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
    {:noreply, state}
  end
  def handle_info(_message, state), do: {:noreply, state}
end
```

Application children immediately after PubSub, independent of reconciler enablement:

```elixir
{Task.Supervisor, name: BurpeeTrainer.CoachMemoryTaskSupervisor, max_children: 2},
BurpeeTrainer.Coach.MemorySubscriber
```

```elixir
test "subscriber processes one event without replay or retries" do
  parent = self()
  tasks = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
  start_supervised!({BurpeeTrainer.Coach.MemorySubscriber,
    name: __MODULE__.Subscriber, task_supervisor: tasks,
    record: fn user, plan, context ->
      send(parent, {:recorded, user, plan, context})
      raise "callback failure"
    end})
  Phoenix.PubSub.broadcast(BurpeeTrainer.PubSub, "workout_finalized",
    {:workout_finalized, %{user_id: 101, workout_plan_id: 202, design_session_id: nil}})
  assert_receive {:recorded, 101, 202, nil}
  _ = :sys.get_state(__MODULE__.Subscriber)
  refute_received {:recorded, 101, 202, nil}
end
```

No init scan, retry loop, outbox, replay, or provider call. Saturated memory tasks may drop an event. Test committed Start/event visibility in the disposable browser database as well as ExUnit's nested-rollback case; sandbox transactions alone are not external commit evidence.

- [ ] **Review gate:** run finalization/memory tests and lifecycle regressions. Start must return the same success when subscriber is absent or its task fails.

---

## Task 8: Real Home workspace, borderless shared action, async loader-only replacement

**Files:** modify `lib/burpee_trainer_web/live/overview_live.ex`; create `home_adjustment.ex`, `components/home_workout_components.ex`; extend `test/burpee_trainer_web/live/overview_live_test.exs`; create `home_adjustment_test.exs`, `overview_revision_test.exs`.

**Contracts:** Home holds one server-owned `HomeSelection`, form from an embedded changeset, expansion/filter state, active async ID, and stream of alternatives. Start/Update is determined from submitted text—not the client label. Existing completed/resume priority and routes are retained. The reviewed layout accepts all shown attributes; no `layouts.ex` edit is needed.

- [ ] **8A red/green:** small form contract:

```elixir
defmodule BurpeeTrainerWeb.HomeAdjustment do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field :instruction, :string, default: ""
  end
  def changeset(data, attrs), do: cast(data, attrs, [:instruction], empty_values: [])
  def operation(text) when is_binary(text) do
    text = String.trim(text)
    cond do
      text == "" -> {:ok, {:start, ""}}
      String.length(text) <= 500 and byte_size(text) <= 4_000 -> {:ok, {:update, text}}
      true -> {:error, :invalid_instruction}
    end
  end
  def operation(_), do: {:error, :invalid_instruction}
end
```

```elixir
defmodule BurpeeTrainerWeb.HomeAdjustmentTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.HomeAdjustment
  test "submitted trimmed text is authoritative" do
    assert {:ok, {:start, ""}} = HomeAdjustment.operation(" \n\t ")
    assert {:ok, {:update, "Less rest"}} = HomeAdjustment.operation(" Less rest ")
    assert {:error, _} = HomeAdjustment.operation(String.duplicate("x", 501))
  end
end
```

Do not use HTML `maxlength=500` as the grapheme authority; its counting differs. Server byte/grapheme checks remain authoritative.

- [ ] **8B red:** update obsolete Home expectations: collapsed contents are now mounted but inert/hidden, not removed. Add these tests to the existing Overview module with its current `recommendation_fixture/1` helper:

```elixir
test "expansion preserves DOM for both transition directions", %{conn: conn, user: user} do
  recommendation_fixture(user)
  {:ok, view, _} = live(conn, ~p"/")
  assert has_element?(view, "#home-expansion[data-open='false']")
  assert has_element?(view, "#home-expansion-content[inert][aria-hidden='true']")
  refute has_element?(view, "#desktop-home-nav")
  view |> element("#home-summary") |> render_click()
  assert has_element?(view, "#home-expansion[data-open='true']")
  refute has_element?(view, "#home-expansion-content[inert]")
  view |> element("#home-summary") |> render_click()
  assert has_element?(view, "#home-expansion-content[inert]")
  assert has_element?(view, "#home-adjustment-form")
end

test "submit does not trust the previous Start label", %{conn: conn, user: user} do
  recommendation_fixture(user)
  {:ok, view, _} = live(conn, ~p"/")
  view |> element("#home-summary") |> render_click()
  view |> form("#home-adjustment-form", home_adjustment: %{instruction: "Less rest"})
    |> render_submit()
  render_async(view)
  assert Workouts.current_started_session(user) == nil
  assert has_element?(view, "#home-action", "Update")
  assert has_element?(view, "#home-adjustment-error")
end
```

- [ ] **8B green:** add aliases `Coach`, `Repo`, `Coach.Catalog`, `Workouts.CoachRecommendation`, `HomeAdjustment`, `HomeWorkoutComponents`, and `Workouts.Inspection` with their full existing namespace spelling. Add `assign_workspace/1` after existing `assign_home/1` in mount. Keep existing completed/week/resume branches and `session_path/1`. Remove the obsolete `start_recommendation`, `use_candidate`, and `keep_current` handlers so forged old events cannot bypass the new Home boundary. Remove their now-unused `rendered_selection/1`, `selection_params/1`, `selection_title/1`, `selection_detail/1`, and `HomeCoachComponents` alias; remove the separate candidate card. Group all `handle_event/3` clauses together (busy guard first, retained Resume/Retry before final catchall), all `handle_async/3` clauses together, and private helpers afterward to avoid clause-grouping warnings.

The complete new workspace helpers and handlers belong inside OverviewLive:

```elixir
defp assign_workspace(socket) do
  socket = socket |> assign(home_selection: nil, expanded?: false, alternatives_open?: false,
    filters_open?: false, active_tab: :workouts, filters: Catalog.default_filters(socket.assigns.current_level),
    instruction: "", busy?: false, update_id: nil, local_error: nil,
    expanded_groups: MapSet.new(), inspection_rows: [], alternatives_empty?: true)
    |> adjustment_form("") |> stream(:alternatives, [])
  if socket.assigns.slot.home_state == :workout_needed and socket.assigns.started_session == nil do
    case Workouts.ensure_home_selection(socket.assigns.current_user, socket.assigns.slot) do
      {:ok, selected} -> show_selection(socket, selected, false)
      {:error, _} -> socket
    end
  else
    socket
  end
end

defp adjustment_form(socket, text), do: assign(socket, adjustment_form:
  to_form(HomeAdjustment.changeset(%HomeAdjustment{}, %{"instruction" => text})))

defp show_selection(socket, selected, expanded?) do
  socket |> assign(home_selection: selected, expanded?: expanded?, instruction: "",
    local_error: nil, expanded_groups: MapSet.new(), alternatives_open?: false,
    inspection_rows: Inspection.rows(selected.plan), start_client_session_id: Ecto.UUID.generate())
    |> adjustment_form("") |> refresh_alternatives()
end

defp refresh_alternatives(socket) do
  a = socket.assigns
  r = Repo.get_by!(CoachRecommendation, id: a.home_selection.recommendation_id,
    user_id: a.current_user.id)
  items = case a.active_tab do
    :workouts ->
      plans = Catalog.order_plans(Workouts.list_library(a.current_user),
        Map.get(r.ranked_plan_ids, "ids", []), a.slot, a.current_level)
      plans = case Workouts.get_draft(a.current_user, r.pending_draft_id) do
        {:ok, pending} -> [pending | plans]
        _ -> plans
      end
      plans |> Catalog.filter(a.filters, &Catalog.plan_level/1)
        |> Enum.map(&%{id: "plan-#{&1.id}", source_id: &1.id, kind: :plan, name: &1.name})
    :videos ->
      BurpeeTrainer.Videos.list_home_videos() |> Catalog.order_videos()
        |> Catalog.filter(a.filters, &Catalog.video_level/1)
        |> Enum.map(&%{id: "video-#{&1.id}", source_id: &1.id, kind: :video, name: &1.name})
  end
  socket |> assign(alternatives_empty?: items == [])
    |> stream(:alternatives, items, reset: true, dom_id: &"home-alternative-#{&1.id}")
end

# Place this before all mutation handlers, including the retained legacy Resume handler.
def handle_event(_event, _params, %{assigns: %{busy?: true}} = socket), do: {:noreply, socket}

def handle_event("toggle_summary", _, socket),
  do: {:noreply, assign(socket, expanded?: not socket.assigns.expanded?)}
def handle_event("toggle_other", _, socket),
  do: {:noreply, assign(socket, alternatives_open?: not socket.assigns.alternatives_open?)}
def handle_event("toggle_filters", _, socket),
  do: {:noreply, assign(socket, filters_open?: not socket.assigns.filters_open?, alternatives_open?: true)}
def handle_event("tab", %{"tab" => tab}, socket) when tab in ["workouts", "videos"] do
  {:noreply, socket |> assign(active_tab: if(tab == "workouts", do: :workouts, else: :videos))
    |> refresh_alternatives()}
end

def handle_event("filter", %{"kind" => kind, "value" => value}, socket) do
  {key, allowed} = if kind == "type", do: {:types, [:six_count, :navy_seal]},
    else: {:levels, BurpeeTrainer.Levels.all_levels()}
  case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
    nil -> {:noreply, socket}
    atom ->
      set = Map.fetch!(socket.assigns.filters, key)
      set = if MapSet.member?(set, atom), do: MapSet.delete(set, atom), else: MapSet.put(set, atom)
      {:noreply, socket |> assign(filters: Map.put(socket.assigns.filters, key, set))
        |> refresh_alternatives()}
  end
end

def handle_event("reset_filters", _, socket), do: {:noreply, socket
  |> assign(filters: Catalog.default_filters(socket.assigns.current_level)) |> refresh_alternatives()}

def handle_event("toggle_group", %{"id" => id}, socket) do
  if Enum.any?(socket.assigns.inspection_rows, &(&1.id == id and &1.count > 1)) do
    set = socket.assigns.expanded_groups
    set = if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
    {:noreply, assign(socket, expanded_groups: set)}
  else
    {:noreply, socket}
  end
end

def handle_event("select_alternative", %{"id" => id, "kind" => kind}, socket) when is_binary(id) do
  with {id, ""} <- Integer.parse(id) do
    a = socket.assigns
    case kind do
      "plan" ->
        case Workouts.select_home_workout(a.current_user, a.home_selection, id) do
          {:ok, selected} -> {:noreply, show_selection(socket, selected, true)}
          _ -> {:noreply, assign(socket, local_error: "That workout is no longer available.")}
        end
      "video" ->
        start_result(socket, Workouts.start_home_video(a.current_user, a.home_selection,
          id, a.start_client_session_id))
      _ -> {:noreply, socket}
    end
  else
    _ -> {:noreply, socket}
  end
end

def handle_event("change_adjustment", %{"home_adjustment" => %{"instruction" => text}}, socket),
  do: {:noreply, socket |> assign(instruction: text) |> adjustment_form(text)}

def handle_event("submit_home_action", params, socket) do
  text = get_in(params, ["home_adjustment", "instruction"])
  a = socket.assigns
  with true <- params["client_session_id"] == a.start_client_session_id,
       {:ok, operation} <- HomeAdjustment.operation(text) do
    case operation do
      {:start, ""} -> start_result(socket,
        Workouts.start_home_workout(a.current_user, a.home_selection, a.start_client_session_id))
      {:update, instruction} ->
        id = make_ref()
        user = a.current_user
        expected = a.home_selection
        {:noreply, socket |> assign(busy?: true, update_id: id, instruction: text, local_error: nil)
          |> start_async({:home_revision, id}, fn -> Coach.revise_home_workout(user, expected, instruction) end)}
    end
  else
    _ -> {:noreply, assign(socket, local_error: "Enter an adjustment of at most 500 characters.")}
  end
end

# After all new and retained event clauses:
def handle_event(_event, _params, socket), do: {:noreply, socket}

defp start_result(socket, {:ok, session}), do: {:noreply, push_navigate(socket, to: session_path(session))}
defp start_result(socket, _), do: {:noreply, assign(socket,
  local_error: "This workout changed or is no longer available. Reopen Home.")}

def handle_async({:home_revision, id}, {:ok, {:ok, selected}},
    %{assigns: %{update_id: id}} = socket) do
  {:noreply, socket |> assign(busy?: false, update_id: nil) |> show_selection(selected, true)}
end

def handle_async({:home_revision, id}, result, %{assigns: %{update_id: id}} = socket) do
  message = case result do
    {:ok, {:error, %{code: :authoring_context_too_large}}} ->
      "This design history is too large to send. Your previous workout is unchanged."
    _ -> "Couldn’t update. Your previous workout is unchanged."
  end
  {:noreply, socket |> assign(busy?: false, update_id: nil, local_error: message)
    |> adjustment_form(socket.assigns.instruction)}
end

def handle_async({:home_revision, _id}, _result, socket), do: {:noreply, socket}
```

The framework supervises `start_async` and keeps LiveView responsive. No socket is captured in the task closure. Busy guards prevent overlapping Updates, stale Start, and selection changes; domain CAS also prevents a different browser tab applying stale results.

- [ ] **8C green:** existing `render/1` still begins with `<Layouts.app ...>`; add `navigation?={false}` and `flash?={false}` using the already-declared attrs. Change the recommendation branch condition from `not is_nil(@recommendation)` to `not is_nil(@home_selection)` and render `<HomeWorkoutComponents.workspace state={assigns} />`; the freshly ensured current-slot selection may exist even when the old pre-ensure recommendation assign was nil. Remove only the old separate candidate section. Keep completed/week/Resume/preparing branches unchanged. A failed timezone lookup never enters this workspace, so it cannot dereference absent progress fields.

Create the component module below. Its persistent expansion DOM plus Task 9 CSS handles **both open and close** without an animation hook. The outer busy `if` intentionally removes the complete readable workout subtree.

```elixir
defmodule BurpeeTrainerWeb.HomeWorkoutComponents do
  use BurpeeTrainerWeb, :html
  alias BurpeeTrainerWeb.CreationParameters
  attr :state, :map, required: true
  def workspace(assigns) do
    ~H"""
    <section id="home-ready-recommendation" class="adaptive-home">
      <div id="home-week-progress">
        <span>Week of {@state.slot.week_start}</span>
        <span>{div(@state.slot.completed_sec, 60)} / {div(@state.slot.weekly_target_sec, 60)} min</span>
      </div>
      <div id="home-workout-area" aria-busy={@state.busy?}>
        <%= if @state.busy? do %>
          <div id="home-update-loading" role="status" aria-label="Updating workout">
            <span class="home-loading-animation" aria-hidden="true"></span>
            <span class="sr-only">Updating workout</span>
          </div>
        <% else %>
          <h1><button id="home-summary" type="button" phx-click="toggle_summary"
            class={["home-summary", @state.expanded? && "home-summary-expanded"]}
            aria-expanded={to_string(@state.expanded?)} aria-controls="home-expansion-content">
            <span class="home-workout-name">{@state.home_selection.plan.name}</span>
            <span class="home-workout-totals">
              {CreationParameters.duration_label(@state.home_selection.plan.target_duration_sec)}
              · {@state.home_selection.plan.target_reps} reps
            </span>
          </button></h1>
          <div id="home-expansion" class="home-expansion" data-open={to_string(@state.expanded?)}>
            <section id="home-expansion-content" class="home-expansion-content"
              inert={!@state.expanded?} aria-hidden={to_string(!@state.expanded?)}>
              <.inspection rows={@state.inspection_rows} expanded={@state.expanded_groups} />
              <div id={"home-editor-#{@state.home_selection.home_revision}"}>
                <.form for={@state.adjustment_form} id="home-adjustment-form"
                  phx-change="change_adjustment" phx-submit="submit_home_action">
                  <input type="hidden" name="client_session_id" value={@state.start_client_session_id} />
                  <.input field={@state.adjustment_form[:instruction]} id="home-adjustment" type="textarea"
                    rows="1" aria-label="Adjust this workout" placeholder="Adjust…"
                    aria-describedby="home-adjustment-error" class="home-adjustment"
                    phx-hook="HomeAdjustment" phx-update="ignore" />
                  <p id="home-adjustment-error" role="status" class="home-local-message">{@state.local_error}</p>
                  <button id="home-action" type="submit" class="home-action">
                    {if String.trim(@state.instruction) == "", do: "Start", else: "Update"}
                    <.icon name="hero-arrow-right" class="size-4" />
                  </button>
                </.form>
              </div>
              <div class="home-other-heading">
                <button id="home-other-workouts" type="button" phx-click="toggle_other"
                  aria-expanded={to_string(@state.alternatives_open?)}>Other workouts</button>
                <button id="home-filter-toggle" type="button" phx-click="toggle_filters"
                  aria-expanded={to_string(@state.filters_open?)}>Filter</button>
              </div>
              <div :if={@state.filters_open?} id="home-filters">
                <div role="group" aria-label="Workout type">
                  <button :for={type <- [:six_count, :navy_seal]} id={"home-type-#{type}"}
                    type="button" phx-click="filter" phx-value-kind="type" phx-value-value={type}
                    aria-pressed={to_string(MapSet.member?(@state.filters.types, type))}>
                    {CreationParameters.type_label(Atom.to_string(type))}
                  </button>
                </div>
                <div role="group" aria-label="Catalog level">
                  <button :for={level <- Enum.reverse(BurpeeTrainer.Levels.all_levels())}
                    id={"home-level-#{level}"} type="button" phx-click="filter"
                    phx-value-kind="level" phx-value-value={level}
                    aria-pressed={to_string(MapSet.member?(@state.filters.levels, level))}>{level_label(level)}</button>
                </div>
                <button id="home-filter-reset" type="button" phx-click="reset_filters">Reset</button>
              </div>
              <div id="home-alternatives-panel" hidden={!@state.alternatives_open?}>
                <div role="tablist" aria-label="Other workouts">
                  <button :for={tab <- [:workouts, :videos]} id={"home-tab-#{tab}"} role="tab"
                    type="button" phx-click="tab" phx-value-tab={tab}
                    aria-selected={to_string(@state.active_tab == tab)}>{if tab == :workouts, do: "Workouts", else: "Videos"}</button>
                </div>
                <p :if={@state.alternatives_empty?} id="home-alternatives-empty" class="home-local-message">
                  No matching workouts. Try changing the filters.
                </p>
                <div id="home-alternatives" phx-update="stream">
                  <button :for={{id, item} <- @state.streams.alternatives} id={id}
                    type="button" phx-click="select_alternative" phx-value-id={item.source_id}
                    phx-value-kind={item.kind} class="home-alternative">{item.name}</button>
                </div>
              </div>
            </section>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :expanded, :any, required: true
  def inspection(assigns) do
    ~H"""
    <div id="home-inspection">
      <table><caption class="sr-only">Exact workout structure</caption>
        <thead><tr><th scope="col">Sets / repeats</th><th scope="col">Prescription and recovery</th></tr></thead>
        <tbody :for={row <- @rows} id={row.id}>
          <tr><th scope="row">
            <button :if={row.count > 1} type="button" phx-click="toggle_group" phx-value-id={row.id}
              aria-expanded={to_string(MapSet.member?(@expanded, row.id))}
              aria-controls={"#{row.id}-details"}>{row.count} ×</button>
            <span :if={row.count == 1}>{if row.trailing?, do: "Final recovery", else: "Interval"}</span>
          </th><td>{summary(row)}</td></tr>
          <tr :if={row.count > 1} id={"#{row.id}-details"} hidden={!MapSet.member?(@expanded, row.id)}>
            <td colspan="2"><ol>
              <li :for={unit <- row.units} id={"#{row.id}-event-#{hd(unit.paired).index}"}>
                {unit_text(unit)}
              </li>
            </ol></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
  defp summary(row), do: row.units |> Enum.take(div(length(row.units), row.count))
    |> Enum.map_join(" / ", &unit_text/1)
  defp unit_text(unit), do: Enum.map_join(unit.paired, "; ", fn %{program: e} ->
    case e["kind"] do
      "work" -> "#{e["reps"]} reps · prescribed cadence #{e["sec_per_rep_us"] / 1_000_000} s/rep · interval #{e["duration_sec"]} s"
      "rest" -> "Recovery #{e["duration_ms"] / 1_000} s"
    end
  end)
  defp level_label(:graduated), do: "Graduated"
  defp level_label(level), do: level |> Atom.to_string() |> String.replace_prefix("level_", "") |> String.upcase()
end
```

`Enum.take` above selects the repeat unit for display only; it is not a history/context truncation. Expansion reveals the complete exact original order. Streams remain mounted while the alternatives panel is hidden, so toggling the panel does not lose consumed stream inserts.

- [ ] **8D red/green:** complete blocked-provider LiveView test. `Req.default_options/0,1` was verified in `deps/req/lib/req.ex:1327–1347`; the real `Client` calls `Req.new/0`, so this reaches its adapter without a production test switch. Global configuration is restored and the test is not async.

```elixir
defmodule BurpeeTrainerWeb.OverviewRevisionTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Coach.Policy

  test "only loading remains, overlap is ignored, failure restores exact source", %{conn: conn} do
    parent = self()
    previous_req = Req.default_options()
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)
    on_exit(fn ->
      Req.default_options(previous_req)
      if previous_provider == nil,
        do: Application.delete_env(:burpee_trainer, :llm_provider),
        else: Application.put_env(:burpee_trainer, :llm_provider, previous_provider)
    end)
    Req.default_options(adapter: fn request ->
      send(parent, {:provider_waiting, self()})
      receive do {:respond, body} -> {request, %Req.Response{status: 200, body: body}} end
    end)
    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true, url: "https://provider.test/v1", api_key: "test", model: "test")
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    {:ok, shown} = Workouts.ensure_home_selection(user, slot)
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    [token] = render(view) |> LazyHTML.from_fragment()
      |> LazyHTML.query("input[name='client_session_id']") |> LazyHTML.attribute("value")
    view |> form("#home-adjustment-form", home_adjustment: %{instruction: "Less rest"})
      |> render_submit()
    assert_receive {:provider_waiting, worker}
    assert has_element?(view, "#home-update-loading")
    for selector <- ["#home-summary", "#home-inspection", "#home-adjustment-form", "#home-action"] do
      refute has_element?(view, selector)
    end
    render_click(view, "submit_home_action", %{"client_session_id" => token,
      "home_adjustment" => %{"instruction" => ""}})
    assert Workouts.current_started_session(user) == nil
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _}
    send(worker, {:respond, Jason.encode!(%{"choices" => [%{"message" => %{"content" => "{}"}}]})})
    render_async(view)
    assert has_element?(view, "#home-summary")
    assert has_element?(view, "#home-adjustment", "Less rest")
    assert has_element?(view, "#home-action", "Update")
    assert has_element?(view, "#home-adjustment-error")
    {:ok, after_failure} = Workouts.ensure_home_selection(user, slot)
    assert after_failure.plan.content_hash == shown.plan.content_hash
    assert after_failure.home_revision == shown.home_revision
  end
end
```

Domain one-call/type-change/retry tests from Task 6 remain the deterministic oracle. Firefox supplies current-run focus and animation proof.

- [ ] **Review gate:** run Home form/Overview/revision/video/creator tests. Preserve existing completed-state priority and Resume tests; remove only superseded acceptance-card expectations. Empty submitted text may Start even if the prior client label was Update; nonblank submitted text must never Start.

---

## Task 9: Bidirectional restrained motion, accessible collapse, and autosize

**Files:** create `assets/css/adaptive_home.css`, `assets/js/hooks/home_adjustment.mjs`, `assets/js/hooks/home_adjustment_test.mjs`; add one CSS import to `assets/css/app.css` and hook registration to `assets/js/app_bootstrap.js`. Preserve existing creator CSS, Tailwind v4 imports/sources, and the one supported app bundle.

**Contract:** the hook manages textarea height only. CSS animates the persistent expansion grid in both directions; `inert` and `aria-hidden` change immediately on collapse, while visibility waits until the 260ms close finishes. Reduced motion removes both transition and delayed visibility. Busy state still removes the readable subtree entirely.

- [ ] **9A red/green:** Node test then implementation:

```javascript
// assets/js/hooks/home_adjustment_test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import HomeAdjustment from "./home_adjustment.mjs";
test("sizes the actual editable control and cleans up", () => {
  const listeners = new Map();
  const el = {style: {}, scrollHeight: 84,
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name, fn) => {
      assert.equal(listeners.get(name), fn); listeners.delete(name);
    }};
  const hook = {el};
  HomeAdjustment.mounted.call(hook);
  assert.equal(el.style.height, "84px");
  el.scrollHeight = 126;
  listeners.get("input")();
  assert.equal(el.style.height, "126px");
  HomeAdjustment.destroyed.call(hook);
  assert.equal(listeners.size, 0);
});
```

```javascript
// assets/js/hooks/home_adjustment.mjs
export default {
  mounted() {
    this.resize = () => {
      this.el.style.height = "auto";
      this.el.style.height = `${this.el.scrollHeight}px`;
    };
    this.el.addEventListener("input", this.resize);
    this.resize();
  },
  destroyed() { this.el.removeEventListener("input", this.resize); },
};
```

In bootstrap: `import HomeAdjustment from "./hooks/home_adjustment.mjs";` and add `HomeAdjustment` to its existing hooks map. Do not create another LiveSocket or inline script.

- [ ] **9B green:** add `@import "./adaptive_home.css";` without disturbing Tailwind source declarations. Complete Home-scoped CSS:

```css
.adaptive-home { max-width: 42rem; margin-inline: auto; color: var(--session-ink);
  font-family: var(--font-sans); padding: 1rem 0 max(1rem, env(safe-area-inset-bottom)); }
#home-week-progress { display: flex; flex-wrap: wrap; justify-content: space-between;
  gap: .5rem 1rem; color: var(--session-muted); font-size: .875rem; }
.home-summary { display: flex; flex-direction: column; align-items: center; gap: .875rem;
  width: 100%; margin-top: clamp(2rem, 18svh, 8rem); padding: 1rem 0; text-align: center;
  cursor: pointer; transition: margin-top 260ms ease, padding 260ms ease; }
.home-summary-expanded { margin-top: 1.5rem; padding-bottom: 1.75rem; }
.home-workout-name { max-width: 100%; overflow-wrap: anywhere; font-size: clamp(2rem, 8vw, 3.5rem);
  font-weight: 600; line-height: 1.08; letter-spacing: -.04em; }
.home-workout-totals { font-size: 1rem; font-weight: 400; color: var(--session-muted);
  font-variant-numeric: tabular-nums; }
.home-expansion { display: grid; grid-template-rows: 0fr; opacity: 0; visibility: hidden;
  transition: grid-template-rows 260ms ease, opacity 260ms ease, visibility 0s linear 260ms; }
.home-expansion[data-open="true"] { grid-template-rows: 1fr; opacity: 1; visibility: visible;
  transition: grid-template-rows 260ms ease, opacity 260ms ease, visibility 0s; }
.home-expansion-content { min-height: 0; overflow: hidden; }
.home-adjustment { display: block; width: 100%; min-height: 2.75rem; padding: .625rem 0;
  border: 0; border-radius: 0; background: transparent; color: var(--session-ink); font: inherit;
  line-height: 1.5; resize: none; overflow-y: hidden; box-shadow: none; }
.home-adjustment::placeholder { color: var(--session-muted); opacity: 1; }
.home-action { display: flex; align-items: center; justify-content: flex-end; gap: .75rem;
  min-height: 2.75rem; margin-left: auto; padding: .625rem 0; cursor: pointer;
  transition: opacity 260ms ease; }
.home-action:hover { opacity: .65; }
.home-local-message { margin-block: .5rem; color: var(--session-muted); font-size: .875rem;
  line-height: 1.5; }
.home-local-message:empty { margin: 0; }
.adaptive-home :is(button, textarea):focus-visible { outline: 2px solid currentColor; outline-offset: 3px; }
#home-inspection table { width: 100%; table-layout: fixed; border-collapse: collapse;
  font-size: .875rem; font-variant-numeric: tabular-nums; }
#home-inspection :is(th, td) { padding: .625rem .25rem; text-align: left; vertical-align: top;
  overflow-wrap: anywhere; border-bottom: 1px solid var(--session-border); }
#home-inspection th:first-child { width: 28%; }
.home-other-heading { display: flex; justify-content: space-between; gap: 1rem; margin-top: 1.5rem; }
.home-other-heading button, #home-filters button, [role="tab"] { min-height: 2.75rem; padding: .5rem; }
#home-filters [role="group"] { display: flex; flex-wrap: wrap; gap: .25rem; }
#home-filters [aria-pressed="true"], [role="tab"][aria-selected="true"] { text-decoration: underline; }
.home-alternative { display: block; width: 100%; min-height: 2.75rem; padding: .75rem 0;
  text-align: left; border-bottom: 1px solid var(--session-border); overflow-wrap: anywhere; }
#home-update-loading { display: grid; min-height: 16rem; place-items: center; }
.home-loading-animation { width: 2rem; height: 2rem; border: 2px solid var(--session-border);
  border-top-color: var(--session-ink); border-radius: 50%; animation: home-loading 900ms linear infinite; }
@keyframes home-loading { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .home-summary, .home-action, .home-expansion, .home-expansion[data-open="true"] { transition: none; }
  .home-loading-animation { animation: none; }
}
```

Keep document scrolling; do not hide overflow globally to conceal layout defects. Expanded region height is content-driven, so large text can scroll. Focus rings must not be clipped at the region's sides; the table/form spacing is verified in Firefox. The existing layout supplies warm session-surface tokens; no prototype font/assets are copied.

- [ ] **Review gate:** `node --test assets/js/hooks/home_adjustment_test.mjs`; `(cd assets && npm test)`; `mix assets.build`. Firefox must observe nonzero opening **and closing** intermediate heights, immediate inertness during close, and zero transition duration under reduced motion.

---

## Task 10: Regression, current-run Firefox evidence, and smoke-ready handoff

**Files:** update `docs/testing/workout-session-e2e.md` only for obsolete Home/Create selectors and the new scenarios; extend `test/burpee_trainer/e2e_library_setup_test.exs` if fixture changes are required; inspect `scripts/e2e/library_setup.exs` before changing its safe fixture setup. Evidence goes under `.e2e-artifacts/`, not into source fixtures.

Parent has authorization to continue directly to implementation/review until smoke-test ready. This document remains a plan; this worker does not start implementation or launch agents.

- [ ] **10A automated gates:** read `mix help test`, `mix help precommit`, and `mix help assets.build` before first use. Run each focused task gate red then green; finish with:

```bash
MIX_ENV=test mix run --no-start scripts/migrations/rehearse_deletion_first.exs
MIX_ENV=test mix test test/burpee_trainer/e2e_library_setup_test.exs --max-cases 1
mix test test/burpee_trainer/workouts/home_selection_test.exs \
  test/burpee_trainer/workouts/inspection_test.exs \
  test/burpee_trainer/workouts/finalization_test.exs \
  test/burpee_trainer/coach/catalog_test.exs \
  test/burpee_trainer/coach/context_test.exs \
  test/burpee_trainer/coach/memory_subscriber_test.exs \
  test/burpee_trainer/coach/draft_authoring_test.exs \
  test/burpee_trainer_web/live/home_adjustment_test.exs \
  test/burpee_trainer_web/live/overview_live_test.exs \
  test/burpee_trainer_web/live/overview_revision_test.exs \
  test/burpee_trainer_web/live/workout_creation_live_test.exs
(cd assets && npm test)
mix assets.build
mix precommit
```

No success claim until all applicable gates pass. Preserve existing snapshot, ownership, availability, compiler precision, video nil-count, and creator Start regressions.

- [ ] **10B real Firefox:** follow `docs/testing/workout-session-e2e.md` exactly: direct `/tmp/adaptive-home-coach-e2e-<run-id>.db`, unique port/server PID with physical cwd proof, generated login URL, mode-600 credentials deleted after authentication, named isolated Firefox profile, redacted evidence, cleanup twice, decoy/trigger survival proof. Do not weaken provider-disabled fixture guards.

Replace obsolete `HOME-CANDIDATE-USE/KEEP` browser instructions with `HOME-CANDIDATE-START`, explicit stored selection, inline revision, and stale-selection cases. Retain domain accept/reject tests. Use a known-count available video for Home filters and retain a separate nil-count Videos regression.

| Scenario | Required current-run evidence |
|---|---|
| Default | Actual week/progress and structured name/duration/reps; no navbar/eyebrow/card paragraph/large Start. |
| Open/close | Summary movement and expanded-section intermediate heights in both directions; no route change; collapsed contents inert and absent from accessibility navigation. |
| Exact inspection | Adjacent identical sets, nonuniform repeats, terminal work and trailing recovery match persisted canonical events before/after expansion. |
| Adjustment | Tap directly focuses textarea; keyboard works; input grows; whitespace/nonblank labels and submitted operations agree. |
| Loading/failure | Only animation occupies workout area; previous plan/hash and instruction restore exactly; one local status, no toast; retry retains failed design context after reload. |
| Published source | Inline selection; failed revision has no orphan draft; successful type-changing revision cannot mutate source or leak another author's log. |
| Atomic Start | Attached draft publication/selection/session snapshot commit together; exact session ID/client UUID/hash; stale tab/token/corrupt candidate cannot partially publish. |
| Alternatives | Actual current/next defaults, independent type filters, shared tabs, reset, stable ranking subsequence, local empty state; no selection/provider request on filter changes. |
| Video | Explicit known-count video starts exact video flow directly; no second Start, plan publication, or finalization callback. |
| Stability | Same-day reload pin unchanged, late candidate remains alternative, two tabs cannot overwrite a new revision, invalid pin converges to fallback. |
| Memory | Only committed finalization event; persisted scoped facts/reasons; missing/failing subscriber does not delay or fail Start. |
| Responsive | Collapsed portrait 390×500 fits at ordinary text; 640×360 and enlarged text scroll naturally without horizontal overflow; reduced motion disables transition and delayed visibility. |
| Fallback | Provider disabled, zero HTTP requests, usable deterministic structured workout. |

Verify the captured session with `mix run scripts/e2e/verify.exs -- USER_ID CLIENT_SESSION_ID`; require exactly one row and the same source ID, session ID, client UUID, immutable hash/program/video snapshot. Existing runner behavior may be regression-tested but this slice does not add reliable interrupted-session checkpoints.

- [ ] **10C external prerequisites:** successful real-provider browser revision remains blocked until both credentials and the separately guarded disposable provider harness described in the runbook exist. The ordinary fixture deliberately disables the provider. Report `Blocked: HOME-UPDATE-SUCCESS — external provider credentials and separately guarded disposable provider harness unavailable.` when applicable. A Req mock is not real-provider evidence. Record Firefox controller/media gaps at the exact failed step, never as passed prototype evidence.

- [ ] **10D review/handoff:** use `jj status`, `jj diff --stat`, and `jj diff -- lib/burpee_trainer/workouts.ex assets/css/app.css` read-only. Parent owns commits and preserved baseline. Report automated/browser passed, failed, or blocked separately; include redacted artifact paths and cleanup proof. No provider credentials, cookies, screenshots of secrets, or raw prompts in logs.

## Correction self-review and traceability

- Stable published-source context lookup/uniqueness, concurrency, independent workspaces, imported owned history, shared-source privacy, and explicit active attempt: Task 5, continued by Task 6.
- Message-building failures, transport exceptions, validation failures, and stale persistence all route through safe outcome recording; logging failure never changes the original error: Task 6 actual code.
- Open and close motion use persistent grid DOM with immediate inertness and reduced-motion rules; updating still removes readable content: Tasks 8–9.
- Core Home selection/Start/commit/context/memory boundaries now include implementation bodies and source-mapped helpers rather than prose-only algorithms: Tasks 1–7.
- `Layouts.app` attributes were checked against the real declaration; `current_scope` is accepted, so no compatibility edit or compiler-warning workaround is planned.
- Spec acceptance 1–4: Tasks 1, 4, 8–9; acceptance 5–8: Tasks 2, 5–6, 8; acceptance 9–10: Tasks 1–3, 8; acceptance 11–12: Tasks 5–7; acceptance 13–14: Tasks 9–10.
- Follow-on History/recovery/global-feedback/weekly-policy surfaces, simulated prototype data, and durable callback machinery remain excluded.
- **Planning validation:** source and plan were inspected; only this markdown artifact was edited. No implementation, tests, provider requests, deployments, or browser acceptance were run during this correction pass.
