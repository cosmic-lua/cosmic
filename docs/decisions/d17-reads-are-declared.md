# D17 — a source declares the data it reads; `require` is not the only edge

- **date:** 2026-07
- **context:** the graph schedules on the import closure, which is
  computed from literal `require("…")` edges. That is every edge a
  module has and not every edge a TEST has: a ratchet reads its subject
  as bytes. `_build/workflows_test.tl` reads `.github/workflows/*.yml`
  (which the model prunes as a dotfile), `_build/skills_test.tl` greps
  `skills/cosmic/*.md` against `_make/types.tl`, and `_build/
  docs_test.tl` compares the decisions index against every record under
  `docs/decisions/`. None of those files was a prerequisite of
  anything, so an incremental `--make test` left the target up to date
  and the stage reported the previous run's pass — a gate reporting on
  a tree that no longer exists. Only a fresh checkout (CI) ran the
  check again, which is the same as saying the local gate had stopped
  being one. The design had recorded the missing piece as a channel for
  "I read this file" that is not `require`, and recorded it as
  deliberately absent.
- **decision:** the channel exists, as a comment line and nothing else:
  `-- @reads <path-or-glob>`, relative to the project root, scanned by
  `_make/reads.tl`, inherited through the import closure so it can live
  beside the `fs.read` that performs it. It expands to the matching
  files **and the directories they came from** — a deletion moves no
  surviving file's mtime — and lands in `o/project.mk` as
  `datadeps_<stem>`, a prerequisite of the test, example and benchmark
  rules. It is **scheduling only**: the recipe line is unchanged, so
  the fence neither widens nor narrows. A declaration that matches
  nothing is a validator error.
- **rejected:** *observed* reads (a depfile written by the `record`
  step from what the test actually opened) — it cannot be forgotten,
  which is its whole appeal, but a test's reads happen in child
  processes and through every API in the standard library, so what it
  observes is silently partial while looking automatic; *deriving from
  string literals* in the source (a heuristic about which literals are
  paths, which is the silent behaviour the model refuses); *narrowing
  the fence onto the same declarations* (scheduling survives an
  incomplete declaration — one stale target — where a grant does not:
  it denies a read in a test that was right, and nothing can check
  completeness); *making the whole file list a prerequisite of the
  ratchets* (every edit re-runs them, which is the other way to make a
  gate useless).
- **consequences:** a declaration names files that exist when the model
  is scanned, so it is for COMMITTED files: a path a `fetch` or a
  generator produces cannot be declared, because on a cold tree it
  matches nothing and the refusal fires. Those are build outputs with
  rules of their own. `_make/fixpoint_test.tl` copies the tree and used
  to prune every dot-prefixed entry, which silently dropped
  `.github/` — the copy was not a smaller version of this project but
  one whose declaration named nothing, and the validator said so. A
  second declaration channel also exists, and it can be forgotten — a read nobody declared schedules nothing, exactly as
  before this record. That is the honest cost, and it is bounded by
  what the validator can see: a declaration that names no file is
  refused, so the failure mode is a missing line rather than a wrong
  one. `--make test` now re-runs a ratchet when its subject changes,
  which is what makes running the gate locally worth anything. The
  channel is also what a future fence narrowing would be built on, once
  something can establish that a test's declarations are complete.
