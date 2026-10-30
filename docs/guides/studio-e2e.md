# Home swipes and the studio: browser end-to-end check

The unit and LiveView tests cannot see layout, gestures or the keyboard. This check drives Home's
swipes and the studio (Edit and New) in a phone-sized browser against a real server, and fails
when something is off. It is not part of `mix precommit`; run it after changing Home, the studio,
the composer or the CSS around them.

## What it checks

- Home has the handle for the swipe up and says what the swipes do on the first visit.
- A swipe right opens the swap drawer and a swipe left closes it; a swipe up opens Edit / New and a
  swipe down closes it; the first swipe is remembered so the hint stops.
- Edit: the studio starts at Home's left edge, the docked box starts at the same edge, nothing
  scrolls sideways, a spinner shows while the coach works, and Save and Run sit under the proposal.
- New: one question at a time, a swipe raises a value by a step, reps say what they come to,
  unbroken asks for a set size, the last screen offers Create workout or Add a request, and Run
  starts the workout.
- Every button is big enough to hit (at least 40px on both sides and 44px on one; the suggestion
  chips, parts and the handle are exempt) and the browser logs no errors.

## Run it

Needs Playwright with Chromium (`npm i -D playwright` anywhere on the module path, or `NODE_PATH`).

```bash
DIR=$(mktemp -d)
export PREVIEW_DIR=$DIR BURPEE_TRAINER_TEST_DATABASE_PATH=$DIR/e2e.db MIX_ENV=test
mix ecto.create && mix ecto.migrate
mix run --no-start scripts/e2e/studio_preview.exs &        # serves until killed; writes $DIR/preview.json
until [ -f $DIR/preview.json ]; do sleep 1; done
SHOTS_DIR=$DIR/shots node scripts/e2e/studio_journey.mjs   # exit 1 if a check fails
kill %1
```

`studio_preview.exs` seeds two athletes (one trained today) and stubs the coach, so no provider call
is made and nothing is paid for. It uses the scratch database only; never point it at a real one.
The server is on `PORT` (default 4000); set `BASE_URL` for another origin. `SHOTS_DIR` keeps a
screenshot of each stage.

Sign-in is a server-signed session cookie for the seeded athlete, not Pocket ID. It proves the
screens, not authentication.

## What it cannot check

A desktop browser has no on-screen keyboard and no iOS edge swipe. Those are in
`docs/guides/ios-device-check.md`.
