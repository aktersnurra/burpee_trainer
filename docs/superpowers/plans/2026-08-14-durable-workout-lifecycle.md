# Durable Workout Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make plan workouts and guided videos create one durable, UUID-keyed lifecycle before activity begins, require unresolved work to be reported or aborted, and safely replay locally retained reports and pose traces.

**Architecture:** `WorkoutSession` becomes a lifecycle aggregate with `running`, `report_pending`, `reported`, and `aborted` states. The server owns lifecycle transitions and the one-unresolved-session constraint; the browser still owns the live timer/camera runtime. IndexedDB is a UUID-keyed recovery outbox for pending completion commands, report drafts, and bounded pose chunks, not the source of truth for whether a session exists.

**Tech Stack:** Phoenix 1.8 / LiveView, Elixir / Ecto / SQLite, JavaScript ES modules, IndexedDB, Node test runner, ExUnit, LazyHTML.

## Global Constraints

- The client owns active timer, camera, and rep-counter execution; the server receives lifecycle commands only at start, local completion, report, and abort boundaries.
- A user may have at most one server row whose `status` is `running` or `report_pending`, across plan and video sources.
- The immutable lifecycle/idempotency UUID is the existing `workout_sessions.client_session_id`; generate it in the browser before the begin request and retain it locally until resolution.
- Direct historical/free-form logging remains a one-transaction `manual` + `reported` row and does not create an unresolved lock.
- Only `reported` rows are workout facts. Running, report-pending, and aborted rows must never affect history, stats, streaks, goals, milestones, PBs, charts, or feed results.
- Never clear a local report draft, completion command, pose chunk, or trace-ready marker until its corresponding server acknowledgement succeeds.
- Pose uploads remain deferred and bounded under the existing request size limits. A retried `(capture run, chunk index)` with different content is a conflict, never an overwrite.
- Use `mix ecto.gen.migration <snake_case_name>` for migrations; do not hand-create migration timestamps.
- Keep `.pi-subagents/**`, `.e2e-artifacts/**`, local databases, generated assets, and `docs/` files unrelated to this feature out of product commits.

---

## File Map

| Path | Responsibility |
| --- | --- |
| `priv/repo/migrations/*_add_workout_session_lifecycle.exs` | Add lifecycle status/source/timestamps, optional video reference, report fingerprint, backfill facts, and enforce one unresolved row per user. |
| `priv/repo/migrations/*_add_pose_trace_chunk_payload_digest.exs` | Add durable digest used to distinguish an idempotent chunk retry from a conflicting replacement. |
| `lib/burpee_trainer/workouts/workout_session.ex` | Model lifecycle/source fields and provide start/report/abort changesets. |
| `lib/burpee_trainer/workouts/pose_trace_chunk.ex` | Persist a payload digest and validate it as server-derived metadata. |
| `lib/burpee_trainer/workouts.ex` | Own lifecycle transitions, idempotency, fact-only queries, and collision-safe trace ingestion. |
| `lib/burpee_trainer/workout_feed.ex` and `lib/burpee_trainer/streak.ex` | Restrict independently authored fact queries to reported rows. |
| `lib/burpee_trainer_web/live/session_live.ex` | Begin a plan lifecycle, mark completion pending, report the existing UUID, and redirect unresolved users. |
| `lib/burpee_trainer_web/live/video_live/show.ex` | Gate video playback on lifecycle start and report its existing UUID after `ended`. |
| `lib/burpee_trainer_web/live/session_resolution_live.ex` | New shared interruption-resolution screen: reconcile draft, manually report, or abort. |
| `lib/burpee_trainer_web/components/session_components.ex` | Reuse durable-session copy/IDs for report-pending and recovery UI where it belongs with session UI. |
| `lib/burpee_trainer_web/router.ex` | Route the resolution LiveView inside the authenticated live session. |
| `lib/burpee_trainer_web/live/session_analysis_live.ex` | Deny analysis for non-reported rows. |
| `assets/js/hooks/session_store.mjs` | Upgrade IndexedDB and add exact-UUID draft/command lookup plus acknowledged cleanup. |
| `assets/js/hooks/session_hook.js` and `assets/js/hooks/session_flow_fsm.mjs` | Persist/replay begin and completion boundaries; wait for lifecycle acknowledgements before starting or showing report. |
| `assets/js/hooks/video_hook.js` | Request server-backed playback start and report-pending after native video end. |
| `assets/js/hooks/session_recovery_hook.js` | New exact-UUID IndexedDB reconciliation and trace-ready handoff for the resolution form. |
| `assets/js/app.js` | Register the recovery hook and preserve global trace retry on mount, reconnect, and page-load stop. |
| `assets/js/hooks/*_test.mjs` | Lock down client state, IndexedDB outbox, recovery, video gate, and uploader idempotency. |
| `test/burpee_trainer/workouts_test.exs` | Cover lifecycle transitions, source constraints, idempotent reports, and fact-query exclusion. |
| `test/burpee_trainer/workouts/pose_capture_test.exs` | Cover digest-aware trace chunk retries. |
| `test/burpee_trainer_web/live/{session_live_test,video_live/show_test,session_resolution_live_test,session_analysis_live_test}.exs` | Cover authenticated routing, lifecycle UI, recovery actions, and analysis restrictions. |
| `test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs` | Cover reported-only trace acceptance, same-content retries, and conflicting retries. |

### Task 1: Add Lifecycle Storage and Schema Invariants

**Files:**

- Create: generated by `mix ecto.gen.migration add_workout_session_lifecycle`
- Modify: `lib/burpee_trainer/workouts/workout_session.ex`
- Test: `test/burpee_trainer/workouts_test.exs`

**Interfaces:**

- Produces `WorkoutSession.status/0` values `:running | :report_pending | :reported | :aborted`.
- Produces `WorkoutSession.source/0` values `:plan | :video | :manual`.
- Produces `WorkoutSession.start_changeset/2`, `WorkoutSession.report_changeset/2`, and `WorkoutSession.abort_changeset/1`.

- [ ] **Step 1: Write failing schema and constraint tests**

```elixir
test "a running plan lifecycle permits missing actuals but a report requires them" do
  running =
    %WorkoutSession{user_id: user.id, plan_id: plan.id}
    |> WorkoutSession.start_changeset(%{
      "client_session_id" => Ecto.UUID.generate(),
      "source" => "plan",
      "burpee_type" => "six_count"
    })

  assert running.valid?
  refute WorkoutSession.report_changeset(Ecto.Changeset.apply_changes(running), %{}).valid?
end

test "database permits only one unresolved lifecycle per user" do
  first =
    %WorkoutSession{user_id: user.id, plan_id: plan.id}
    |> WorkoutSession.start_changeset(%{
      "client_session_id" => Ecto.UUID.generate(),
      "source" => "plan",
      "burpee_type" => "six_count"
    })

  second =
    %WorkoutSession{user_id: user.id, plan_id: plan.id}
    |> WorkoutSession.start_changeset(%{
      "client_session_id" => Ecto.UUID.generate(),
      "source" => "plan",
      "burpee_type" => "six_count"
    })

  assert {:ok, _} = Repo.insert(first)
  assert {:error, changeset} = Repo.insert(second)
  assert "has already been taken" in errors_on(changeset).user_id
end
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `mix test test/burpee_trainer/workouts_test.exs`

Expected: compilation failure because lifecycle fields and lifecycle changesets are absent.

- [ ] **Step 3: Generate and write the migration**

Run: `mix ecto.gen.migration add_workout_session_lifecycle`

Implement the generated migration with these operations:

```elixir
alter table(:workout_sessions) do
  add :status, :string, null: false, default: "reported"
  add :source, :string, null: false, default: "manual"
  add :video_id, references(:workout_videos, on_delete: :nilify_all)
  add :report_fingerprint, :string
  add :report_pending_at, :utc_datetime
  add :reported_at, :utc_datetime
  add :aborted_at, :utc_datetime
end

execute("UPDATE workout_sessions SET source = 'plan' WHERE plan_id IS NOT NULL")
execute("UPDATE workout_sessions SET reported_at = inserted_at WHERE status = 'reported'")
create index(:workout_sessions, [:video_id])
create unique_index(:workout_sessions, [:user_id],
  where: "status IN ('running', 'report_pending')",
  name: :workout_sessions_one_unresolved_per_user_index
)
```

Model fields and changesets explicitly:

```elixir
field :status, Ecto.Enum, values: [:running, :report_pending, :reported, :aborted], default: :reported
field :source, Ecto.Enum, values: [:plan, :video, :manual], default: :manual
field :report_fingerprint, :string
field :report_pending_at, :utc_datetime
field :reported_at, :utc_datetime
field :aborted_at, :utc_datetime
belongs_to :video, WorkoutVideo
```

`start_changeset/2` validates UUID, source, status `:running`, and known burpee type without actual values; it declares `unique_constraint(:user_id, name: :workout_sessions_one_unresolved_per_user_index)` so the partial-index collision is a changeset error. `report_changeset/2` validates actual count/duration then sets `:reported`; `abort_changeset/1` sets `:aborted` and `aborted_at` without casting browser fields.

- [ ] **Step 4: Run migration and focused tests**

Run: `mix ecto.migrate && mix test test/burpee_trainer/workouts_test.exs`

Expected: migration succeeds; lifecycle schema tests pass; existing session tests fail only where their assertions need an explicit `:reported` expectation.

- [ ] **Step 5: Commit the storage slice**

```bash
jj describe -m "feat(workouts): add durable session lifecycle schema"
jj new
```

### Task 2: Implement Server-Owned, Idempotent Lifecycle Transitions

**Files:**

- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `lib/burpee_trainer/workouts/workout_session.ex`
- Test: `test/burpee_trainer/workouts_test.exs`

**Interfaces:**

- Consumes Task 1 changesets and lifecycle fields.
- Produces:

```elixir
begin_plan_session(User.t(), WorkoutPlan.t(), Ecto.UUID.t())
begin_video_session(User.t(), WorkoutVideo.t(), Ecto.UUID.t())
mark_report_pending(User.t(), Ecto.UUID.t())
report_session(User.t(), Ecto.UUID.t(), map(), map())
abort_session(User.t(), Ecto.UUID.t())
get_unresolved_session(User.t())
change_session_for_report(WorkoutSession.t(), map())
```

`report_session/4` returns `{:ok, session, :reported | :existing}`. Transition errors return `{:error, :not_found | :aborted | :report_conflict | {:unresolved_session, WorkoutSession.t()} | Ecto.Changeset.t()}`.

- [ ] **Step 1: Add failing transition/idempotency tests**

```elixir
test "report replay returns existing without applying milestones twice" do
  uuid = Ecto.UUID.generate()
  assert {:ok, running} = Workouts.begin_plan_session(user, plan, uuid)
  assert {:ok, pending} = Workouts.mark_report_pending(user, uuid)
  assert pending.status == :report_pending

  attrs = %{"burpee_count_actual" => 12, "duration_sec_actual" => 120}
  assert {:ok, reported, :reported} = Workouts.report_session(user, uuid, attrs, %{})
  assert {:ok, ^reported, :existing} = Workouts.report_session(user, uuid, attrs, %{})
end

test "a different replay payload cannot overwrite a reported session" do
  uuid = reported_session_uuid(user, plan)

  assert {:error, :report_conflict} =
           Workouts.report_session(user, uuid, %{"burpee_count_actual" => 99, "duration_sec_actual" => 120}, %{})
end

test "abort is idempotent but cannot abort a reported session" do
  uuid = Ecto.UUID.generate()
  assert {:ok, _} = Workouts.begin_plan_session(user, plan, uuid)
  assert {:ok, aborted} = Workouts.abort_session(user, uuid)
  assert {:ok, ^aborted} = Workouts.abort_session(user, uuid)
end
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `mix test test/burpee_trainer/workouts_test.exs`

Expected: failures for undefined lifecycle functions.

- [ ] **Step 3: Implement transition functions in one transaction per command**

Use the user-scoped UUID as the durable identity. Derive all plan/video source fields on the server. Use the partial unique index as the concurrent-writer backstop.

```elixir
def get_unresolved_session(%User{id: user_id}) do
  Repo.one(
    from session in WorkoutSession,
      where: session.user_id == ^user_id and session.status in [:running, :report_pending],
      preload: [:plan, :video]
  )
end

def mark_report_pending(%User{} = user, client_session_id) do
  transition_session(user, client_session_id, fn
    %WorkoutSession{status: :running} = session ->
      session
      |> Ecto.Changeset.change(status: :report_pending, report_pending_at: DateTime.utc_now(:second))
      |> Repo.update()

    %WorkoutSession{status: status} = session when status in [:report_pending, :reported] ->
      {:ok, session}

    %WorkoutSession{status: :aborted} ->
      {:error, :aborted}
  end)
end
```

Build `report_fingerprint` from a fixed keyword list of normalized persisted attributes and tracking provenance, then hash `:erlang.term_to_binary(list)` with `:crypto.hash(:sha256)`. On an already reported row, equal fingerprints return `:existing`; unequal fingerprints return `:report_conflict`. Only the `running/report_pending -> reported` branch invokes derived-field and milestone/style side effects.

Refactor `create_session_from_plan/3`, `create_tracked_session_from_plan/4`, and `create_free_form_session/2` so legacy callers still return `{:ok, session}`, but runtime paths use `report_session/4` to update the original row.

- [ ] **Step 4: Run context tests**

Run: `mix test test/burpee_trainer/workouts_test.exs`

Expected: lifecycle, existing capture-mode, and existing plan/free-form idempotency tests pass.

- [ ] **Step 5: Commit the transition slice**

```bash
jj describe -m "feat(workouts): add idempotent session lifecycle transitions"
jj new
```

### Task 3: Make Every Fact Read Model Reported-Only

**Files:**

- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `lib/burpee_trainer/workout_feed.ex`
- Modify: `lib/burpee_trainer/streak.ex`
- Modify: `lib/burpee_trainer_web/live/session_analysis_live.ex`
- Test: `test/burpee_trainer/workouts_test.exs`
- Test: `test/burpee_trainer_web/live/session_analysis_live_test.exs`

**Interfaces:**

- Consumes Task 1 `WorkoutSession.status`.
- Produces a private `reported_session` query predicate consistently applied to all fact queries.

- [ ] **Step 1: Add failing read-model tests**

```elixir
test "unresolved and aborted sessions do not affect weekly minutes, history, or last plan" do
  reported = reported_session(user, plan, 600)
  _running = running_session(user, plan)
  _pending = report_pending_session(user, plan)
  _aborted = aborted_session(user, plan)

  assert Workouts.list_sessions(user) == [reported]
  assert [%{minutes: 10.0}] = Workouts.weekly_minutes(user)
  assert Workouts.last_run_plan(user).id == plan.id
end

test "analysis redirects for a non-reported tracked session", %{conn: conn, user: user} do
  session = report_pending_session(user, plan_fixture(user))
  assert {:error, {:live_redirect, %{to: "/stats"}}} = live(conn, ~p"/stats/sessions/#{session.id}")
end
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/session_analysis_live_test.exs`

Expected: current queries include unresolved rows or analysis accepts them.

- [ ] **Step 3: Apply a reported-state predicate to all fact reads**

Update every `WorkoutSession` query that derives user-facing facts, including:

```elixir
where: session.user_id == ^user_id and session.status == :reported
```

Cover `list_sessions`, paginated history, weekly minutes, trained days, last-run plan, baseline/qualification/chart queries, goals/milestones, gamification, rolling style performance, `WorkoutFeed`, and `Streak`. Preserve explicit preloads and current ordering. In `SessionAnalysisLive`, require both `session.status == :reported` and tracked capture mode.

- [ ] **Step 4: Run scoped regression tests**

Run: `mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer/streak_test.exs test/burpee_trainer_web/live/session_analysis_live_test.exs`

Expected: reported rows retain current behavior; non-facts never appear or contribute.

- [ ] **Step 5: Commit the read-model slice**

```bash
jj describe -m "fix(workouts): exclude unresolved sessions from facts"
jj new
```

### Task 4: Add the Shared Resolution Route and Manual Report Flow

**Files:**

- Create: `lib/burpee_trainer_web/live/session_resolution_live.ex`
- Modify: `lib/burpee_trainer_web/router.ex`
- Modify: `lib/burpee_trainer_web/components/session_components.ex`
- Test: `test/burpee_trainer_web/live/session_resolution_live_test.exs`

**Interfaces:**

- Consumes `Workouts.get_unresolved_session/1`, `report_session/4`, and `abort_session/2`.
- Produces authenticated route `GET /sessions/:id/resolve` and IDs `#session-resolution`, `#session-resolution-form`, `#session-resolution-abort`, and `#session-resolution-status`.

- [ ] **Step 1: Write failing LiveView tests**

```elixir
test "shows the unresolved source and a manual report form", %{conn: conn, user: user} do
  session = report_pending_session(user, plan_fixture(user))
  {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/resolve")

  assert has_element?(view, "#session-resolution[data-client-session-id='#{session.client_session_id}']")
  assert has_element?(view, "#session-resolution-form")
  assert has_element?(view, "#session-resolution-abort")
end

test "manual report updates the original lifecycle row", %{conn: conn, user: user} do
  session = running_session(user, plan_fixture(user))
  {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/resolve")

  view |> form("#session-resolution-form", workout_session: %{burpee_count_actual: 8, duration_sec_actual: 90}) |> render_submit()
  assert Workouts.get_session!(user, session.id).status == :reported
end
```

- [ ] **Step 2: Run the test file and verify failure**

Run: `mix test test/burpee_trainer_web/live/session_resolution_live_test.exs`

Expected: route and LiveView are absent.

- [ ] **Step 3: Implement the user-scoped resolver**

Add the authenticated route:

```elixir
live "/sessions/:id/resolve", SessionResolutionLive
```

In `mount/3`, load only a user-owned row whose status is `:running` or `:report_pending`, preload plan/video source, and redirect to `/stats` for missing or resolved rows. Build `to_form(Workouts.change_session_for_report(session))`; never read a changeset in HEEx.

Use a normal `<.form for={@form} id="session-resolution-form" phx-submit="report">` with imported `<.input>` fields. The submit handler calls `Workouts.report_session/4` using `@session.client_session_id`; success navigates to `/stats`. The abort button uses `phx-click="abort"`, calls `Workouts.abort_session/2`, then navigates to `/workouts`. Keep the source-derived type/planned values read-only; only actuals and report fields are user input.

- [ ] **Step 4: Run LiveView tests**

Run: `mix test test/burpee_trainer_web/live/session_resolution_live_test.exs`

Expected: manual reporting and abort transition the original row; unauthorized/resolved IDs redirect safely.

- [ ] **Step 5: Commit the resolution slice**

```bash
jj describe -m "feat(web): add unfinished session resolution"
jj new
```

### Task 5: Gate Plan Session Start and Persist Completion Boundaries

**Files:**

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `assets/js/hooks/session_flow_fsm.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_store.mjs`
- Test: `test/burpee_trainer_web/live/session_live_test.exs`
- Test: `assets/js/hooks/session_flow_fsm_test.mjs`
- Test: `assets/js/hooks/session_hook_flow_test.mjs`
- Test: `assets/js/hooks/session_store_test.mjs`

**Interfaces:**

- Consumes `begin_plan_session/3` and `mark_report_pending/2` from Task 2.
- Produces LiveView events `begin_session` and `mark_report_pending`.
- Produces exact UUID storage methods:

```js
store.saveLifecycleCommand(command)
store.loadLifecycleCommand(clientSessionId)
store.deleteLifecycleCommand(clientSessionId)
store.loadDraftByClientSessionId(clientSessionId)
```

- [ ] **Step 1: Add failing client and LiveView tests**

```js
test("runner waits for begin acknowledgement before starting warmup", async () => {
  const hook = mountedHook({ pushEventReply: { begin_session: { status: "ok", client_session_id: "uuid-1" } } });
  hook.onWarmupYes();
  assert.equal(hook.flow.mode, "starting_session");
  await flushPromises();
  assert.equal(hook.flow.mode, "warmup_running");
});

test("completion persists an outbox command before report_pending request", async () => {
  const hook = mountedHook();
  hook.finishLocalWorkout();
  await hook.draftWrite;
  assert.deepEqual(store.commandKinds(), ["mark_report_pending"]);
});
```

```elixir
test "unresolved plan lifecycle redirects instead of booting a second runner", %{conn: conn, user: user} do
  running_session(user, plan_fixture(user))
  plan = plan_fixture(user)
  assert {:error, {:live_redirect, %{to: "/sessions/" <> _ <> "/resolve"}}} = live(conn, ~p"/session/#{plan.id}")
end
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs js/hooks/session_store_test.mjs && cd .. && mix test test/burpee_trainer_web/live/session_live_test.exs`

Expected: missing outbox APIs/events and no unresolved redirect.

- [ ] **Step 3: Upgrade storage and runner command flow**

Bump the IndexedDB version and create a `lifecycle_commands` store keyed by `client_session_id`. Store a `begin_session` command before emitting it and store a `mark_report_pending` command plus completion draft before emitting it. Do not key recovery lookup by plan/program hash; add exact UUID lookup while retaining the old migration-safe method until all callers move.

Add FSM intermediate modes that disable start/save actions while server acknowledgement is pending:

```js
{ type: "SESSION_BEGIN_REQUESTED" } // -> starting_session
{ type: "SESSION_BEGIN_ACKNOWLEDGED", clientSessionId } // -> warmup_running or workout_running
{ type: "REPORT_PENDING_REQUESTED" } // -> reporting_completion
{ type: "REPORT_PENDING_ACKNOWLEDGED" } // -> completion_review
```

`SessionLive.mount/3` first checks `Workouts.get_unresolved_session(user)`. If present, `push_navigate` to its resolution route. Add a `begin_session` event that calls `Workouts.begin_plan_session(user, plan, client_session_id)`, and a `mark_report_pending` event that calls `Workouts.mark_report_pending(user, client_session_id)`. The final `save_session` calls `Workouts.report_session/4`, never an insert function.

Only delete the begin/completion command after its matching successful reply. Preserve the current local draft after a failed reply. On finalized report success, mark trace upload ready with the returned existing row ID, then clean up the report command/draft.

- [ ] **Step 4: Run focused client and LiveView tests**

Run: `cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs js/hooks/session_store_test.mjs && cd .. && mix test test/burpee_trainer_web/live/session_live_test.exs`

Expected: no runner begins before durable start acknowledgement; completion report cannot render before pending acknowledgement; failure leaves exact-UUID recovery data intact.

- [ ] **Step 5: Commit the plan runner lifecycle slice**

```bash
jj describe -m "feat(session): persist workout lifecycle boundaries"
jj new
```

### Task 6: Give Guided Videos the Same Durable Lifecycle

**Files:**

- Modify: `lib/burpee_trainer_web/live/video_live/show.ex`
- Modify: `assets/js/hooks/video_hook.js`
- Modify: `assets/js/app.js`
- Test: `test/burpee_trainer_web/live/video_live/show_test.exs`
- Test: `assets/js/hooks/video_hook_test.mjs`

**Interfaces:**

- Consumes `begin_video_session/3`, `mark_report_pending/2`, and `report_session/4`.
- Produces DOM IDs `#video-start-workout`, `#workout-video`, and `#video-log-form[data-client-session-id]`.

- [ ] **Step 1: Write failing video lifecycle tests**

```js
test("video pauses a native play attempt until begin acknowledgement", async () => {
  const hook = mountedVideoHook();
  hook.el.dispatchEvent(new Event("play"));
  assert.equal(hook.el.paused, true);
  assert.equal(hook.events[0].event, "begin_video_session");
});

test("ended requests report pending before showing the report", async () => {
  const hook = mountedVideoHook();
  hook.el.dispatchEvent(new Event("ended"));
  assert.equal(hook.events[0].event, "mark_video_report_pending");
});
```

```elixir
test "video does not render a playable session until its lifecycle starts", %{conn: conn} do
  video = video_fixture()
  {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}")
  assert has_element?(view, "#video-start-workout")
  refute has_element?(view, "#video-log-form")
end
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `cd assets && node --test js/hooks/video_hook_test.mjs && cd .. && mix test test/burpee_trainer_web/live/video_live/show_test.exs`

Expected: native hook only emits `video_ended`; no durable start event exists.

- [ ] **Step 3: Implement the video start gate and existing-row report**

Render a visible `<button id="video-start-workout" type="button">Start workout</button>` before enabling playback. `VideoHook` handles that click, generates and retains `crypto.randomUUID()`, and pushes `begin_video_session` with `client_session_id`. The LiveView begin handler calls `Workouts.begin_video_session/3` and replies with that UUID. The hook calls `video.play()` only after success; it pauses an unapproved native `play` event.

On native `ended`, `VideoHook` requests `mark_video_report_pending` with the same UUID. `VideoLive.Show` changes `log_visible` only after `Workouts.mark_report_pending/2` succeeds. Its save handler calls `Workouts.report_session/4` for the stored UUID. It redirects to the shared resolver when another unresolved lifecycle exists and never uses `create_free_form_session/2` for a guided video.

Register the updated hook in `assets/js/app.js` only if it is exported under a new name; otherwise preserve the existing hook registry key.

- [ ] **Step 4: Run focused tests**

Run: `cd assets && node --test js/hooks/video_hook_test.mjs && cd .. && mix test test/burpee_trainer_web/live/video_live/show_test.exs`

Expected: video lifecycle start, end, report, and unresolved redirection behave like plan workouts.

- [ ] **Step 5: Commit the video slice**

```bash
jj describe -m "feat(video): require durable workout reporting"
jj new
```

### Task 7: Reconcile Exact-UUID Local Recovery Data

**Files:**

- Create: `assets/js/hooks/session_recovery_hook.js`
- Create: `assets/js/hooks/session_recovery_hook_test.mjs`
- Modify: `assets/js/hooks/session_store.mjs`
- Modify: `assets/js/app.js`
- Modify: `lib/burpee_trainer_web/live/session_resolution_live.ex`
- Test: `test/burpee_trainer_web/live/session_resolution_live_test.exs`

**Interfaces:**

- Consumes `data-client-session-id` and `data-session-status` on `#session-resolution`.
- Produces LiveView event `reconcile_local_completion` and browser event `burpee:trace-upload-ready` after confirmed manual reporting.

- [ ] **Step 1: Write failing recovery tests**

```js
test("replays a locally completed running session by exact UUID", async () => {
  const hook = mountedRecoveryHook({
    status: "running",
    draft: { client_session_id: "uuid-1", completion_command: true, burpee_count_actual: 9 },
  });

  await hook.reconcile();
  assert.deepEqual(hook.events, [{ event: "reconcile_local_completion", payload: { client_session_id: "uuid-1" } }]);
});

test("prefills only a matching report-pending UUID", async () => {
  const hook = mountedRecoveryHook({ status: "report_pending", draft: { client_session_id: "uuid-1", burpee_count_actual: 9 } });
  await hook.reconcile();
  assert.equal(hook.el.querySelector("#workout_session_burpee_count_actual").value, "9");
});
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `cd assets && node --test js/hooks/session_recovery_hook_test.mjs && cd .. && mix test test/burpee_trainer_web/live/session_resolution_live_test.exs`

Expected: the hook and reconciliation event do not exist.

- [ ] **Step 3: Implement server-driven recovery with client prefill**

Render the resolver root as:

```heex
<div
  id="session-resolution"
  phx-hook="SessionRecoveryHook"
  data-client-session-id={@session.client_session_id}
  data-session-status={@session.status}
>
```

The hook opens the store, calls `loadDraftByClientSessionId`, and never falls back to plan/program matching. For a `running` row containing a persisted completion command, it `pushEvent`s `reconcile_local_completion` and waits for reply before filling inputs. For a `report_pending` row it fills compatible local draft fields and dispatches input events. It leaves the server-rendered manual form untouched when storage is unavailable or UUID does not match.

The LiveView reconciliation handler calls `mark_report_pending` and replaces its form assign from the stored payload only after normal server validation. After manual report success, the hook uses the reply session ID to mark remaining local trace chunks ready, then emits `burpee:trace-upload-ready`; it removes report/outbox data only after that acknowledgement chain succeeds.

- [ ] **Step 4: Run focused recovery tests**

Run: `cd assets && node --test js/hooks/session_recovery_hook_test.mjs && cd .. && mix test test/burpee_trainer_web/live/session_resolution_live_test.exs`

Expected: matching local data restores/replays safely; stale/missing local data leaves manual resolution available.

- [ ] **Step 5: Commit the recovery slice**

```bash
jj describe -m "feat(session): recover durable local completion drafts"
jj new
```

### Task 8: Strengthen Idempotent Deferred Pose Uploads

**Files:**

- Create: generated by `mix ecto.gen.migration add_pose_trace_chunk_payload_digest`
- Modify: `lib/burpee_trainer/workouts/pose_trace_chunk.ex`
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `assets/js/hooks/pose_trace_uploader.mjs`
- Test: `test/burpee_trainer/workouts/pose_capture_test.exs`
- Test: `test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs`
- Test: `assets/js/hooks/pose_trace_uploader_test.mjs`

**Interfaces:**

- Produces `PoseTraceChunk.payload_digest` as server-derived SHA-256 of canonical encoded `payload_json`.
- `ingest_pose_trace_batch/4` returns `{:error, :chunk_conflict}` when a previously accepted index has different content.

- [ ] **Step 1: Add failing trace idempotency tests**

```elixir
test "same chunk index and content is an acknowledged retry but changed content conflicts", %{conn: conn} do
  {_, session} = saved_session(user)
  first = upload_payload(session.client_session_id, [chunk(0)])
  changed = put_in(first, ["chunks", Access.at(0), "payload", "samples"], [%{"tMs" => 0, "changed" => true}])

  assert json_response(post(auth(conn, user), ~p"/api/session-pose-traces", first), 200)["accepted_indexes"] == [0]
  assert json_response(post(auth(recycle(conn), user), ~p"/api/session-pose-traces", changed), 409) == %{"error" => "chunk_conflict"}
end

test "pose endpoint rejects an unresolved lifecycle", %{conn: conn, user: user, plan: plan} do
  {:ok, session} = Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())
  assert json_response(post(auth(conn, user), ~p"/api/session-pose-traces", upload_payload(session.client_session_id, [chunk(0)])), 404)
end
```

```js
test("conflict response retains every local chunk and ready marker", async () => {
  const store = uploadStore([chunk(0)]);
  await createPoseTraceUploader({ store, fetch: async () => response(409), csrfToken: "token" }).drain();
  assert.deepEqual(store.remainingIndexes(), [0]);
  assert.equal(store.uploadMarkerExists(), true);
});
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `cd assets && node --test js/hooks/pose_trace_uploader_test.mjs && cd .. && mix test test/burpee_trainer/workouts/pose_capture_test.exs test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs`

Expected: altered content is currently acknowledged because `on_conflict: :nothing` does not compare payloads; unresolved rows are accepted by plan ID.

- [ ] **Step 3: Implement digest-aware ingestion**

Generate the migration, add non-null `payload_digest` to stored chunks, then derive it from `payload_json` in the context:

```elixir
digest = payload_json |> :crypto.hash(:sha256) |> Base.encode16(case: :lower)
```

Before accepting a duplicate index, fetch its existing row. Equal digest contributes the index to `accepted_indexes`; unequal digest returns `{:error, :chunk_conflict}` and rolls back the whole batch. Handle the insert race by re-fetching after the unique-index conflict and comparing the digest. Change the session lookup in `ingest_pose_trace_batch/4` to require both `plan_id` and `status: :reported`.

Keep uploader behavior deliberately simple: every non-2xx response, including 409, preserves chunks and marker for later inspection/retry. Do not report an empty success acknowledgement as progress.

- [ ] **Step 4: Run focused upload tests**

Run: `cd assets && node --test js/hooks/pose_trace_uploader_test.mjs && cd .. && mix test test/burpee_trainer/workouts/pose_capture_test.exs test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs`

Expected: same content is idempotent, altered content is rejected, unresolved rows cannot receive traces, and client queues survive any failure.

- [ ] **Step 5: Commit the trace slice**

```bash
jj describe -m "fix(tracking): verify deferred trace retry content"
jj new
```

### Task 9: Run End-to-End Lifecycle Verification

**Files:**

- Test: `test/burpee_trainer/workouts_test.exs`
- Test: `test/burpee_trainer_web/live/session_live_test.exs`
- Test: `test/burpee_trainer_web/live/video_live/show_test.exs`
- Test: `test/burpee_trainer_web/live/session_resolution_live_test.exs`
- Test: `test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs`
- Verify: `docs/testing/workout-session-e2e.md`

**Interfaces:**

- Consumes all lifecycle commands and recovery hooks from Tasks 1–8.
- Produces evidence that duplicate requests are harmless and recovery never starts a second unresolved workout.

- [ ] **Step 1: Add cross-boundary regression cases**

```elixir
test "one unresolved video blocks a plan and manual reporting unlocks the next start" do
  {:ok, video_session} = Workouts.begin_video_session(user, video, Ecto.UUID.generate())
  assert {:error, {:unresolved_session, ^video_session}} =
           Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())

  assert {:ok, _, :reported} =
           Workouts.report_session(user, video_session.client_session_id, manual_report_attrs(), %{})

  assert {:ok, _} = Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())
end
```

- [ ] **Step 2: Run all focused automated suites**

Run:

```bash
cd assets && node --test js/hooks/session_store_test.mjs js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs js/hooks/session_recovery_hook_test.mjs js/hooks/video_hook_test.mjs js/hooks/pose_trace_uploader_test.mjs
cd .. && mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer/workouts/pose_capture_test.exs test/burpee_trainer_web/live/session_live_test.exs test/burpee_trainer_web/live/session_resolution_live_test.exs test/burpee_trainer_web/live/video_live/show_test.exs test/burpee_trainer_web/live/session_analysis_live_test.exs test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs
```

Expected: all focused JS and ExUnit tests pass.

- [ ] **Step 3: Perform required real-browser E2E checks**

Follow `docs/testing/workout-session-e2e.md` and prove:

1. Start a plan, close/reload before completion, then resolve it manually or abort it before a new start.
2. Finish a plan, reload before save, then see the prefilled report when IndexedDB data remains.
3. Start and finish a video, reload before report save, then resolve the same server row.
4. Fail a pose upload, reload/navigate, and confirm the bounded trace queue later succeeds without duplicate chunks.

- [ ] **Step 4: Run the project verification alias**

Run: `mix precommit`

Expected: formatter, compilation, and the complete test suite pass.

- [ ] **Step 5: Inspect the final working-copy diff and commit verification fixes**

```bash
jj diff --stat
jj describe -m "test(session): verify durable lifecycle recovery"
jj new
```

Only commit source, migrations, tests, and feature documentation. Do not include `.pi-subagents/**`, `.e2e-artifacts/**`, local databases, or generated files.

## Plan Self-Review

- **Spec coverage:** Tasks 1–2 establish durable lifecycle status, one-active-user enforcement, first-transition side effects, and command idempotency. Task 3 prevents lifecycle rows from affecting fact read models. Tasks 4–7 supply shared manual resolution, plan/video gates, exact-UUID local recovery, and safe cleanup. Task 8 makes trace retries content-safe. Task 9 validates cross-source lock behavior plus browser recovery.
- **Placeholder scan:** The only wildcard paths are Mix-generated migration timestamps, which are intentionally produced by the mandated generator commands. No implementation steps defer behavior or omit an interface.
- **Type consistency:** All client/server boundaries use `client_session_id`; all lifecycle state uses `running`, `report_pending`, `reported`, and `aborted`; report replay outcomes are `:reported` or `:existing`; pose conflicts are `:chunk_conflict`.
