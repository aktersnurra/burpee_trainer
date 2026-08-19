# Workout Session Browser E2E

This is the canonical, agent-agnostic browser acceptance procedure for the
client-authoritative workout session. Use it for release verification and after
changes to session flow, persistence, layout, camera tracking, or uploads.

Automated JavaScript and ExUnit suites remain mandatory. They do not replace
this browser E2E, and this browser E2E does not replace them.

## Required capabilities

Use any browser controller that can:

- launch an isolated named browser profile or session;
- inspect and interact through roles, labels, or stable selectors;
- set a viewport and scroll a specific container;
- inspect DOM attributes, dimensions, focus, and computed styles;
- record network requests and temporarily block routes;
- preserve IndexedDB across reloads in the same browser profile.

Never use an unlabeled shared browser tab. Keep one browser session, origin,
server port, and test identity for the entire scenario.

## Acceptance rules

An agent may report **passed** only when it has current-run evidence for:

1. the fresh server belongs to the current workspace and revision;
2. completion controls can be reached by real container scrolling;
3. a completion choice changes both accessible and visible pressed state;
4. Save navigates successfully;
5. exactly one database row exists for the captured `client_session_id`.

If browser automation, authentication, camera hardware, or network inspection
fails, report that portion as **blocked**. Unit tests are not substitute E2E
evidence.

## Prepare the workspace

From the repository root:

```bash
mkdir -p .e2e-artifacts/{screenshots,network,reports,server}
jj workspace root
jj status
mix precommit
mix assets.build
```

Choose an unused port and start a fresh server from this workspace. Record the
PID, port, revision, and physical working directory.

```bash
E2E_PORT=4030
E2E_BASE_URL="http://127.0.0.1:$E2E_PORT"
PORT="$E2E_PORT" mix phx.server \
  >".e2e-artifacts/server/$E2E_PORT.log" 2>&1 &
E2E_SERVER_PID=$!

for _attempt in {1..100}; do
  curl --fail --silent "$E2E_BASE_URL/login" >/dev/null && break
  kill -0 "$E2E_SERVER_PID" || exit 1
  sleep 0.1
done
curl --fail --silent "$E2E_BASE_URL/login" >/dev/null
```

Verify that the listening PID's current directory equals `jj workspace root`.
On macOS, `lsof -a -p "$E2E_SERVER_PID" -d cwd` provides that evidence; use
the operating-system equivalent elsewhere. Do not test an older server from
another workspace.

## Create isolated test data

```bash
E2E_BASE_URL="$E2E_BASE_URL" mix run scripts/e2e/setup.exs
```

The final output line starts with `E2E_SETUP=` and contains JSON with:

- `user_id`, `username`, and a generated password;
- `plan_id`;
- `login_url` and `session_url`.

Treat the password as ephemeral secret material. Do not save the raw setup
output in screenshots, reports, or committed files.

## Mandatory scenario: complete, scroll, interact, Save

Use a new named browser profile such as `workout-session-e2e-<run-id>`.

1. Open `login_url`, sign in, and open `session_url`.
2. Set a compact mobile viewport, preferably `390x500` or smaller.
3. Confirm the capture-choice heading receives focus.
4. Choose **No, continue**.
5. Choose **Skip warmup**.
6. Choose **Start workout** and wait for the runner.
7. Pause, choose **Finish early**, and accept its confirmation.
8. On completion review, collect these DOM facts:
   - `#session-completion-review` is visible and has no `inert` attribute;
   - its direct child scroll container has `overflow-y: auto`;
   - `scrollHeight` is greater than `clientHeight` at the compact viewport.
9. Scroll `#session-completion-review > div` to its maximum scroll offset.
   Confirm `scrollTop` changes and the Save button enters the viewport.
10. Click one mood or tag button. Confirm `aria-pressed` changes and computed
    background, border, or text color visibly distinguishes the selected state.
11. Capture the runtime `client_session_id` from `#burpee-session`.
12. Click **Save session** and wait for navigation to `/stats`.
13. Verify persistence:

```bash
mix run scripts/e2e/verify.exs -- USER_ID CLIENT_SESSION_ID
```

The command must emit `E2E_VERIFY=` with `count: 1`. A zero or duplicate count
fails the scenario.

## Mandatory scenario: offline local runtime and draft restoration

Use a fresh setup identity or clean the prior run first.

1. Load `session_url` while connected, then begin network capture.
2. After the HTML, JavaScript, and optional static camera resources load, block
   future application requests for the active origin.
3. Exercise the no-camera path through completion review.
4. Confirm no application API request, trace upload, or Save occurred during
   the local workout. Browser resource or reconnection attempts must be listed
   separately from application requests.
5. Edit completion values and record the original `client_session_id`.
6. Restore connectivity before reloading; the server-rendered page shell is not
   an offline service worker. Reload the same session URL.
7. Confirm the draft restores with the same values and original client ID.
8. Save, navigate, and run `scripts/e2e/verify.exs`. The count must be one.

## Conditional scenario: controlled pose fixture continuity

Run this only when the browser controller can both inject a page-init script
and intercept the normal app-asset response. Build the test-only fixture entry:

```bash
mix assets.fixture
```

Before loading the session page, configure the controller to fulfill the
normal `/assets/js/app.js` request from `tmp/e2e-assets/app_fixture.js` with a
JavaScript content type. Do not serve, upload, or deploy that file: it is a
local E2E-only replacement entrypoint. The normal production app asset does
not contain the fixture runtime. In the same page-init script, initialize
`window.__burpeePoseFixture = {frames: []}` before the fixture entry runs.

The fixture entry passes those client-only feature frames through the injected
`controlledPoseFixture` tracker runtime seam instead of requesting a physical
camera.

Place the fixed phone on or near the floor, facing the athlete, far enough away
to keep the head, wrists, hips, knees, ankles, and feet in frame while standing
and on the floor. The controlled fixture must carry BlazePose-shaped world
landmarks. A cropped or low-confidence frame is an absent observation; it must
not generate a warning or a report fallback.

Each ready frame must meet that full-body contract, contain one visible pose,
and have feature confidence at least `0.5`; provide eight such frames to finish
camera setup.

1. Choose **Yes, use camera**, feed the ready frames, then use the ordinary
   camera setup, warmup, and workout controls.
2. After the workout runner begins, append one complete macro-cycle to
   `window.__burpeePoseFixture.frames`.
3. Append low-confidence absent frames covering at least two seconds, followed
   by a second complete macro-cycle.
4. Confirm the displayed count is two; no `tracking degraded` or `out of
   frame` text appears; and Save remains enabled.
5. Save and run `scripts/e2e/verify.exs` for the captured client UUID. Confirm
   exactly one reported row with the saved tracked result.

Do not use a camera-health status as acceptance evidence. If the controlled
fixture cannot run in the browser, mark this scenario blocked and cite the
focused automated fixture and tracker tests separately. Do not call it
browser-passed.

## Visual and accessibility checks

At portrait and `640x360` short-landscape viewports, verify:

- no horizontal or document-level overflow;
- the active panel heading receives focus without scrolling the page;
- Enter and Space toggle pause when the pause control is focused;
- all blue rest and recovery screens use `session-blue-breathe` unless reduced
  motion is enabled;
- reduced motion disables animation without hiding progress;
- completion field errors and global Save errors are announced;
- scrollbars remain visually hidden while targeted scrolling still works;
- browser zoom remains disabled by the viewport contract.

## Evidence report

Write a concise report under `.e2e-artifacts/reports/` containing:

- workspace root, revision, server PID, port, and server working directory;
- browser/controller name, profile/session name, and viewport;
- one row per scenario: `passed`, `failed`, or `blocked`;
- measured scroll values plus the clicked control's accessible and computed
  visual state change;
- captured client ID and redacted `E2E_VERIFY` result;
- application-request summary;
- screenshot, trace, or network artifact paths;
- explicit gaps, including unavailable camera hardware.

Never include passwords, cookies, CSRF tokens, or raw browser profile data.

## Cleanup

After evidence is recorded:

```bash
mix run scripts/e2e/cleanup.exs -- USER_ID
kill "$E2E_SERVER_PID"
```

Cleanup refuses to delete users without the `e2e_workout_` prefix. Confirm the
browser session is closed and the server process has stopped.

## Failure policy

Do not modify source code while a scenario is in progress. On failure:

1. preserve evidence;
2. report the exact failed observation;
3. reproduce with a focused automated test when possible;
4. fix test-first;
5. restart from a fresh server, browser profile, and test identity.
