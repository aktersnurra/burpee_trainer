# Workout Library and Session Browser E2E

This is the canonical authenticated Firefox procedure for the deletion-first workout library,
recommendation Home, immutable plan/video sessions, History, and optional pose evidence. Automated
ExUnit and Node suites remain mandatory; they do not replace current-run browser evidence.

## Required capabilities

Use Firefox with an isolated named profile and a controller that can:

- inspect and interact through labels, roles, and stable DOM IDs;
- set mobile and short-landscape viewports and scroll a specific container;
- inspect focus, accessibility state, dimensions, and computed styles;
- record browser requests and, when required, server-side provider request counts;
- block and restore application-origin requests;
- preserve IndexedDB through reloads in the same profile.

Keep one workspace directory, server PID, port, direct database path, browser profile, and fixture
identity together. Do not reuse an unlabeled tab or a server from another checkout.

## Acceptance and blocker rules

Report a scenario **passed** only with current-run evidence. In particular:

1. the server process working directory is this repository root;
2. the user authenticated through the generated `login_url`;
3. Start navigated to the exact server-created session ID;
4. reload/resume retained that ID and the immutable snapshot/content hash;
5. completion updated the same session once;
6. `scripts/e2e/verify.exs` reported exactly one row for the captured client UUID.

Report browser-control, authentication, camera, network-inspection, or provider-credential gaps as
**blocked**, with the exact attempted step and external prerequisite. An automated test citation is
supporting context, never substitute browser evidence.

## Automated prerequisites

From the repository root, require all commands to exit zero:

```bash
MIX_ENV=test mix run --no-start scripts/migrations/rehearse_deletion_first.exs
MIX_ENV=test mix test test/burpee_trainer/e2e_library_setup_test.exs --max-cases 1
(cd assets && npm test)
mix assets.build
MIX_ENV=test mix precommit
mkdir -p .e2e-artifacts/{screenshots,network,reports,server}
```

This runbook contains no version-control commands. Record the physical working directory with `pwd`
and the server PID/current directory with the operating-system process tools (for example,
`lsof -a -p "$E2E_SERVER_PID" -d cwd` on macOS).

## Disposable database safety

Every fixture database must be an absolute, normalized, direct lexical child of `/tmp`:

```text
/tmp/adaptive-home-coach-e2e-<nonempty-run-id>.db
```

Do not use an environment-resolved temp root, `/private/tmp` in the supplied path, nested
directories, `..`, alternate parents, symlinks, an existing non-regular target, the development/test
database, or production.
macOS may resolve literal `/tmp` to `/private/tmp`; runtime validation allows only that platform
resolution. Invalid paths are refused before Repo startup.

The fixture marker forces the provider off and points the Repo only at the marked database. The six
supported setup modes are:

```text
published-plan
pending-candidate
available-video
started-plan-session
completed-history
provider-failure
```

Each mode is deterministic and retry-safe for the same run ID. Use a fresh database and browser
profile for an independent destructive scenario, especially each candidate outcome.

## Create a fixture database

Choose an unused port and a lowercase/number run ID. The example creates one `started-plan-session`;
replace `MODE` and the suffix for each matrix row.

```bash
export E2E_PORT=4030
export E2E_BASE_URL="http://127.0.0.1:$E2E_PORT"
export E2E_MODE="started-plan-session"
export E2E_RUN_ID="$(date +%s)-started"
export E2E_ADAPTIVE_DATABASE_PATH="/tmp/adaptive-home-coach-e2e-$E2E_RUN_ID.db"
export E2E_ADAPTIVE_FIXTURE=1

test "$(dirname "$E2E_ADAPTIVE_DATABASE_PATH")" = "/tmp"
test ! -e "$E2E_ADAPTIVE_DATABASE_PATH"
test ! -e "$E2E_ADAPTIVE_DATABASE_PATH-wal"
test ! -e "$E2E_ADAPTIVE_DATABASE_PATH-shm"

mix ecto.create --quiet
mix ecto.migrate --quiet
export E2E_SECRET_SETUP_FILE="/tmp/adaptive-home-coach-e2e-$E2E_RUN_ID-setup-secret.log"
install -m 600 /dev/null "$E2E_SECRET_SETUP_FILE"
mix run scripts/e2e/library_setup.exs -- "$E2E_MODE" >"$E2E_SECRET_SETUP_FILE"
test "$(stat -f '%Lp' "$E2E_SECRET_SETUP_FILE")" = "600"

E2E_SECRET_SETUP_FILE="$E2E_SECRET_SETUP_FILE" mix run --no-start -e '
line =
  System.fetch_env!("E2E_SECRET_SETUP_FILE")
  |> File.read!()
  |> String.split("\n")
  |> Enum.find(&String.starts_with?(&1, "E2E_LIBRARY_SETUP="))

report = line |> String.replace_prefix("E2E_LIBRARY_SETUP=", "") |> Jason.decode!()
IO.puts("E2E_LIBRARY_SETUP=" <> Jason.encode!(Map.put(report, "password", "[REDACTED]")))
' >".e2e-artifacts/server/$E2E_RUN_ID-setup-redacted.log"
```

The mode-600 `/tmp` file is the only credential-bearing setup output. The separate artifact contains
the same mode-specific IDs, snapshots, and URLs with `password` redacted. For the normal session
scenario, `mix run scripts/e2e/setup.exs` is also supported, but its complete output must be handled
through the same mode-600 secret-file and redaction steps rather than written to an artifact.

Never copy the generated password into screenshots, reports, terminal excerpts, or repository files.

Start a fresh server against exactly the same marked database before attempting browser
authentication or deleting the credential-bearing file:

```bash
PHX_SERVER=true PORT="$E2E_PORT" mix phx.server \
  >".e2e-artifacts/server/$E2E_RUN_ID.log" 2>&1 &
export E2E_SERVER_PID=$!

for _attempt in $(seq 1 100); do
  curl --fail --silent "$E2E_BASE_URL/login" >/dev/null && break
  kill -0 "$E2E_SERVER_PID" || exit 1
  sleep 0.1
done
curl --fail --silent "$E2E_BASE_URL/login" >/dev/null
pwd
lsof -a -p "$E2E_SERVER_PID" -d cwd
```

Fixture runtime aligns the endpoint URL, LiveView origin allowlist, and production-style connection
pool with this exact `PORT`; any reconnect alert or origin/checkout error is a failed run.

Only after the final readiness request and server working-directory proof succeed, open the emitted
`login_url` in a new isolated Firefox profile named `deletion-first-e2e-<run-id>`. Have the browser
controller read the generated username/password directly from the mode-600 temporary file; do not
echo, source, or copy them through terminal history. Authenticate, then immediately after successful
authentication delete the credential-bearing file and prove it is absent:

```bash
rm -f -- "$E2E_SECRET_SETUP_FILE"
test ! -e "$E2E_SECRET_SETUP_FILE"
```

Retain the isolated profile only for the scenario. If server readiness or authentication fails,
follow the failure policy, which also requires removing this file and proving its absence.

## Scenario matrix

| ID | Fixture | Required current-run evidence |
| --- | --- | --- |
| `LIB-PUBLISHED` | `published-plan` | Published and Draft sections; exact published row; Start available |
| `LIB-AUTHOR` | conditional real provider | one Create request, durable draft after reload, one Refine request, explicit Publish before Start |
| `HOME-CANDIDATE-USE` | `pending-candidate` | Use publishes/selects atomically and clears pending draft |
| `HOME-CANDIDATE-KEEP` | fresh `pending-candidate` | Current workout is better deletes alternative and retains selection |
| `HOME-FALLBACK` | `provider-failure` | disabled provider makes zero HTTP requests and published fallback remains usable |
| `SESSION-PLAN` | `started-plan-session` | exact session ID/client UUID/hash; reload/resume; one completion update |
| `SESSION-VIDEO` | `available-video` | Start creates exact video session snapshot, including nil-count semantics when applicable |
| `HISTORY-ARCHIVE` | `completed-history` | archive source plan; History/Stats retain snapshot name/type/targets/result |
| `SESSION-OFFLINE` | fresh `started-plan-session` | local runner and draft survive blocked requests; reconnect saves one row |
| `POSE-EVIDENCE` | fresh `started-plan-session` | controlled/real tracking when available; exact completed-session association |

### Published and Draft Library

1. With `published-plan`, open `/workouts`.
2. Require `#workout-library-page`, `#published-heading`, `#published-workouts`, `#draft-heading`, and
   `#draft-workouts`.
3. Match the fixture's `plan_id`, state, name, definition/program, and content hash to the rendered
   published entry.
4. Require `#start-workout-PLAN_ID`; do not claim that a draft can Start.
5. Exercise Copy on a fresh run if desired and require a new draft without changing the published
   source.

### Real-provider Create, Refine, persistence, and Publish

This scenario is conditional. The marked disposable fixture deliberately sets provider configuration
to disabled before application startup, even if credentials are present. It is the safe authority for
zero-request fallback, not successful provider traffic.

Successful real-provider verification remains blocked unless both external
`LLM_PROVIDER_URL`/`LLM_PROVIDER_API_KEY` credentials and a separately guarded disposable provider
harness are supplied. That harness must refuse production, development, test, and ordinary fixture
databases before Repo startup; own only an exact direct `/tmp` database and sidecars; use a dedicated
disposable identity; enable provider traffic only under its separate explicit marker; count outbound
requests; and provide exact cleanup. The repository does not currently supply that harness. Never use
production, the normal development database, the ordinary test database, or the provider-disabled
fixture lane for successful provider verification.

Only after those external credentials and that guarded harness are supplied:

1. create the harness-owned fresh database and start its isolated server;
2. start server-side outbound request counting before interaction;
3. open `/workouts`, submit `#workout-create-form` once, and require exactly one provider HTTP request;
4. require the result only under Drafts and refute a published/start control for it;
5. reload `/workouts` and require the same draft ID, definition, program, and content hash;
6. submit `#refine-workout-DRAFT_ID` once and require exactly one additional provider request;
7. require successful refine to replace that same draft atomically;
8. click `#publish-workout-DRAFT_ID`; require it to move to Published before Start becomes available;
9. record redacted request timestamps/statuses and persisted state, never headers or credentials;
10. use the harness's exact cleanup and prove its server is stopped before database removal.

Until both prerequisites exist, report exactly:

```text
Blocked: LIB-AUTHOR — external provider credentials and separately guarded disposable provider harness unavailable.
```

Do not add credentials to the marked fixture, weaken any runtime guard, or infer successful
one-request behavior from the disabled-provider test.

### Pending candidate outcomes

For `HOME-CANDIDATE-USE`:

1. create `pending-candidate`, authenticate, and open `/`;
2. require `#home-ready-recommendation` and `#home-pending-candidate`;
3. record `recommendation_id`, selected plan ID, pending draft ID/state/hash;
4. click `#use-candidate-button`;
5. require the candidate to be published, selected, and absent from Drafts after reload;
6. require Home Start to reference the newly selected published plan.

For `HOME-CANDIDATE-KEEP`, create a completely fresh database and profile:

1. record the original selection and pending draft ID;
2. click `#keep-current-workout-button`;
3. reload Home and Library;
4. require the original selection unchanged and the alternative draft absent.

A stale tab, missing candidate, unexpected extra plan, orphan draft, or candidate action outside
`workout_needed` fails the scenario.

### Disabled-provider fallback

1. Create `provider-failure` and retain its report.
2. Require `provider_enabled: false`, `provider_result: "provider_unavailable"`,
   `provider_request_count: 0`, `fallback_available: true`, and a published selected plan.
3. Authenticate and open Home. Require `#home-ready-recommendation` and a usable Start action.
4. Capture browser and server traffic from setup through Home render; require no provider request.
5. If Retry is rendered, it may return the bounded unavailable result, but must not remove fallback.

This scenario verifies disabled-provider zero-request behavior only. It does not satisfy the
conditional real-provider Create/Refine observations.

### Exact plan session, resume, completion, and verifier

1. Create `started-plan-session` and record `session_id`, `client_session_id`, `content_hash`,
   `program_snapshot`, and `session_url`.
2. Open exactly `/session/SESSION_ID`. Confirm the page's session ID and Work/Rest payload match the
   report before interacting.
3. Reload the exact URL. Require the same ID, client UUID, content hash, plan snapshot, and runner
   state restoration; no new session row may appear.
4. At a compact `390x500` viewport, use the no-camera path, Skip warmup, Start, Pause, Finish early,
   and confirm.
5. On completion review, require `#session-completion-review` to be visible and non-inert. Scroll its
   direct overflow container until Save is in view.
6. Select feedback and require both accessible pressed state and visible computed-style change.
7. Save once and require navigation to Stats/History.
8. Run the read-only verifier against the same marked database:

```bash
mix run scripts/e2e/verify.exs -- USER_ID CLIENT_SESSION_ID
```

Require one `E2E_VERIFY=` object with `count: 1`, the exact `session_id`, `state: "completed"`, client
UUID, source identity (`plan_id` and `workout_video_id`, including the expected `null`), content hash,
program/video snapshot, planned reps/duration, actual
reps/duration, pre/post notes, mood, all three context booleans, primary limiter, preference,
completion time, capture mode, `cadence_ms`, target pace, pace consistency, and tags. It must also
report the exact pose run ID/user/session/status and ordered chunk count/indexes/digests, using explicit
`null`, `0`, and `[]` values when capture evidence is absent. A zero/duplicate row, changed
ID/hash/snapshot, second insert, or provider request fails.

### Offline local runner and draft restoration

1. Load a fresh started session while connected and record its exact immutable identity.
2. After HTML, app JavaScript, and optional camera assets load, block subsequent application-origin
   requests.
3. Complete the local workout and edit completion values. Require no Save/upload request while
   blocked.
4. Restore connectivity before reload; there is no offline service-worker shell.
5. Reload the same session URL. Require the same client UUID and restored completion draft.
6. Save and run `scripts/e2e/verify.exs`; require exactly one completed row.

### Exact video snapshot

1. Create `available-video` and record its video ID, name, filename, availability, snapshot, and hash.
2. Open `/videos`, start that exact available video, and capture the server-created session URL before
   runner load.
3. Require `source_kind: video`, no plan program snapshot, and exact video snapshot fields used at
   Start: media identity, name, workout type, format, duration, and reps (including `nil` when the
   catalog row has no count).
4. Reload/resume, complete once, and run `scripts/e2e/verify.exs` for the captured UUID.
5. Require the verifier's `workout_video_id` to equal the started video ID, `plan_id` to be `null`,
   and the persisted `video_snapshot` and content hash to remain exact after completion.

If the environment cannot serve the fixture's media, record playback/completion as blocked while
retaining the snapshot/route observations; do not invent a media file or claim playback passed.

### Archived-plan History stability

1. Create `completed-history`, authenticate, and record the report's persisted snapshot name,
   workout type, planned reps/duration, program/hash, actual reps/duration, pre/post notes, mood,
   context booleans, limiter, preference, capture mode/metrics, pose run/chunk evidence, and timestamp.
2. Open `/workouts`, archive the fixture `plan_id`, and confirm it disappears from normal Published
   selection and cannot Start.
3. Open `/stats` and History. Require the completed entry to retain all recorded snapshot facts.
4. Reload both views. No text, target, result, feedback, or capture fact may be read from mutable plan
   content or disappear after archival.

### Pose/tracking evidence

Use a fresh started plan. Prefer real camera evidence only when all landmarks remain in frame. A
controller with page-init injection may instead run the repository's controlled pose fixture after:

```bash
mix assets.fixture
```

Serve `tmp/e2e-assets/app_fixture.js` only as a local response replacement for the normal app asset;
never deploy or upload it. Provide complete BlazePose-shaped world landmarks through
`window.__burpeePoseFixture`, complete at least one tracked rep, save, and verify:

- exactly one completed session for the client UUID;
- `pose_capture_run_id`, `pose_capture_run_user_id`, and
  `pose_capture_run_workout_session_id` identify that exact owned completed session;
- `pose_capture_run_status` is `completed`, and `pose_capture_chunk_count` equals the lengths of the
  ordered `pose_capture_chunk_indexes` and `pose_capture_chunk_digests` arrays;
- those exact chunk indexes/digests remain present after History reload;
- retransmission is not manufactured in the browser.

If controlled injection and suitable camera hardware are unavailable, record `POSE-EVIDENCE` as
blocked and cite focused pose tests separately. Do not call camera-health text acceptance evidence.

## Visual and accessibility checks

At portrait `390x500` and short landscape `640x360`, verify:

- no horizontal or document-level overflow;
- focused panel headings are visible;
- completion content scrolls independently and Save is reachable;
- selected feedback has accessible and visible state;
- keyboard pause/resume works when the control is focused;
- reduced motion disables animation without hiding progress;
- validation and Save errors are announced;
- Library Published/Draft hierarchy and Home candidate actions remain readable.

## Evidence report

Write a report under `.e2e-artifacts/reports/` containing:

- physical workspace path, server PID/port/current directory, direct database path;
- Firefox/controller and isolated profile name;
- one `passed`, `failed`, or `blocked` row per scenario;
- redacted setup facts and fixture mode, plus proof the mode-600 secret file was deleted after auth;
- Published/Draft selectors and persisted draft/publish evidence;
- real-provider Create/Refine request counts or the precise external blocker;
- fallback zero-request evidence and both candidate outcomes;
- exact session ID/client UUID/hash/snapshot before and after reload/completion;
- exact video snapshot and any media-serving blocker;
- archived-plan History facts matching the persisted setup/verifier fields;
- exact pose run identity/status and ordered chunk count/indexes/digests, or the exact
  hardware/controller blocker;
- redacted `E2E_VERIFY` showing `count: 1` and all planned, actual, notes, mood, typed feedback,
  capture metrics, and pose evidence fields described above;
- application/provider network summary and artifact paths;
- cleanup results from both calls and both decoy/trigger survival proofs.

Never include passwords, provider keys, cookies, CSRF tokens, raw browser profiles, or unredacted
sensitive headers.

## Cleanup twice

Before the first target cleanup, create an unrelated decoy user, video row, and marker file in the
same disposable run. Record their exact IDs plus the lifecycle trigger digest in a non-secret
artifact:

```bash
export E2E_DECOY_USERNAME="e2e_decoy_$(printf '%s' "$E2E_RUN_ID" | shasum -a 256 | cut -c1-12)"
export E2E_DECOY_FILENAME="unrelated-$E2E_RUN_ID.mp4"
export E2E_DECOY_FILE="/tmp/unrelated-e2e-$E2E_RUN_ID.marker"
export E2E_DECOY_REPORT=".e2e-artifacts/server/$E2E_RUN_ID-decoy.log"
test ! -e "$E2E_DECOY_FILE"
printf 'unrelated:%s\n' "$E2E_RUN_ID" >"$E2E_DECOY_FILE"

mix run -e '
alias BurpeeTrainer.{Accounts, Repo, Videos}
username = System.fetch_env!("E2E_DECOY_USERNAME")
filename = System.fetch_env!("E2E_DECOY_FILENAME")
{:ok, user} = Accounts.register_user(%{"username" => username, "password" => Ecto.UUID.generate()})
{:ok, video} = Videos.create_video(%{name: "Unrelated cleanup decoy", filename: filename,
  burpee_type: :six_count, duration_sec: 60, burpee_count: nil, available: true,
  format: :follow_along})
[[trigger_sql]] = Repo.query!("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?",
  ["trigger", "workout_plans_draft_only_delete_trigger"]).rows
sha256 = fn value -> :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) end
IO.puts("E2E_DECOY=" <> Jason.encode!(%{user_id: user.id, username: user.username,
  video_id: video.id, video_filename: video.filename,
  file_path: System.fetch_env!("E2E_DECOY_FILE"),
  file_digest: sha256.(File.read!(System.fetch_env!("E2E_DECOY_FILE"))),
  lifecycle_trigger_digest: sha256.(trigger_sql)}))
' | tee "$E2E_DECOY_REPORT"
```

Define this proof command. It fails unless the exact initially recorded IDs, marker bytes, and
lifecycle trigger all still exist:

```bash
verify_e2e_decoy() {
  E2E_DECOY_REPORT_PATH="$E2E_DECOY_REPORT" mix run -e '
  alias BurpeeTrainer.{Accounts, Repo}
  alias BurpeeTrainer.Workouts.WorkoutVideo
  line = System.fetch_env!("E2E_DECOY_REPORT_PATH") |> File.read!()
    |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "E2E_DECOY="))
  expected = line |> String.replace_prefix("E2E_DECOY=", "") |> Jason.decode!()
  user = Accounts.get_user_by_username(expected["username"])
  video = Repo.get_by!(WorkoutVideo, filename: expected["video_filename"])
  [[trigger_sql]] = Repo.query!("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?",
    ["trigger", "workout_plans_draft_only_delete_trigger"]).rows
  sha256 = fn value -> :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) end
  true = user.id == expected["user_id"]
  true = video.id == expected["video_id"]
  true = sha256.(File.read!(expected["file_path"])) == expected["file_digest"]
  true = sha256.(trigger_sql) == expected["lifecycle_trigger_digest"]
  IO.puts("E2E_DECOY_SURVIVES=" <> Jason.encode!(expected))
  '
}
```

Invoke target cleanup twice while the server remains confined to the marked database, and run the
proof after each call:

```bash
mix run scripts/e2e/cleanup.exs -- USER_ID \
  | tee ".e2e-artifacts/server/$E2E_RUN_ID-cleanup-first.log"
verify_e2e_decoy \
  | tee ".e2e-artifacts/server/$E2E_RUN_ID-decoy-after-first.log"

mix run scripts/e2e/cleanup.exs -- USER_ID \
  | tee ".e2e-artifacts/server/$E2E_RUN_ID-cleanup-second.log"
verify_e2e_decoy \
  | tee ".e2e-artifacts/server/$E2E_RUN_ID-decoy-after-second.log"
```

Require the first `E2E_CLEANUP=` result to report deletion, the second to report
`status: "already_absent"`, and both `E2E_DECOY_SURVIVES=` reports to retain exactly the initially
recorded IDs and digests. Close the Firefox profile. Then send termination, wait for process exit,
and only afterward remove the exact database, sidecars, and explicitly named decoy marker:

```bash
kill "$E2E_SERVER_PID"
for _attempt in $(seq 1 100); do
  kill -0 "$E2E_SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$E2E_SERVER_PID" 2>/dev/null; then
  kill -KILL "$E2E_SERVER_PID"
fi
wait "$E2E_SERVER_PID" || true
! kill -0 "$E2E_SERVER_PID" 2>/dev/null

rm -f -- \
  "$E2E_ADAPTIVE_DATABASE_PATH" \
  "$E2E_ADAPTIVE_DATABASE_PATH-wal" \
  "$E2E_ADAPTIVE_DATABASE_PATH-shm" \
  "$E2E_DECOY_FILE"
```

Never use wildcard cleanup.

## Failure policy

Do not modify source while a scenario is active. On failure:

1. preserve redacted evidence;
2. report the exact failed observation and exit/status;
3. remove the credential-bearing setup file and prove it is absent, whether readiness,
   authentication, or a later scenario step failed:

   ```bash
   rm -f -- "$E2E_SECRET_SETUP_FILE"
   test ! -e "$E2E_SECRET_SETUP_FILE"
   ```

4. stop the server and run safe cleanup twice;
5. reproduce with a focused automated test when possible;
6. fix test-first;
7. restart with a new direct `/tmp` path, Firefox profile, and identity.
