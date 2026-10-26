# Replaying recorded camera sessions

Every camera session uploads its pose trace. Replaying those traces through the current rep
counter shows how it does on real sessions, and they are what the counter's model is fitted
from. Design: `docs/specs/2026-10-26-burpee-hsmm-design.md`.

## 1. Export

Copy the production SQLite file somewhere local (the server's `DATABASE_PATH`), then:

```sh
mix burpee_trainer.export_pose_corpus .docs/pose-corpus --database path/to/copy.db
```

Only the Repo starts; nothing migrates or runs jobs against the copy. Without
`--database` it reads the configured dev database. Keep exports in the git-ignored `.docs/`:
they hold body landmarks.

## 2. Report

```sh
node assets/js/tools/pose_corpus_report.mjs .docs/pose-corpus assets/js/hooks/fixtures
```

Per session: the logged count, the session's camera count, the replayed count, whether a
version 2 trace's replay reproduces the reps the camera emitted live (traces from before
2026-10-26 are version 1: they lack dropouts, so replay is optimistic), and the replay's
reps matched to the program's schedule. The schedule is a rep-by-rep label only for sessions
where you kept up. The command exits non-zero if a version 2 replay differs from live.

## 3. Refit

```sh
node assets/js/tools/fit_burpee_hsmm.mjs .docs/pose-corpus assets/js/hooks/fixtures \
  > .docs/pose_burpee_hsmm_model.mjs
cp .docs/pose_burpee_hsmm_model.mjs assets/js/hooks/pose_burpee_hsmm_model.mjs
```

It refits only from sessions the current model already counts exactly, and keeps a pass
only if no fewer sessions count exactly afterwards. Then rerun the report and the asset
tests (`cd assets && npm test`); keep the new model only if the report is at least as good
on every session, otherwise restore the file from version control.
