## Goal

G4, under the tree-migration container (3IOCdooE): batch 1 of seven —
the internal trees except _cli and _make lose their test self-call lines, so those files run because
the toolchain found their cases (D29). The container's spec carries the
facts every batch shares; this one names the scope.

## Evidence (measured 2026-08-27 against origin/main at cb39b65d)

- **Scope**: `_build/`, `_docs/`, `_types/`, `3p/`, `_fuzz/`, `_eval/`, `_perf/`, `_tool/`.
- **481 self-call lines across 73 files**, counted with the
  same pattern the edit deletes:

  ```
  grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _build _docs _types 3p _fuzz _eval _perf _tool | xargs grep -hc '^test_[A-Za-z0-9_]*()$' | paste -sd+ | bc
  ```

  Re-run it at pull; the tree grows, so treat a moved number as
  detail drift and refresh the line rather than bouncing.
- **Every file in scope reaches runner mode after the deletion** — 0
  of 275 tree-wide do not, measured with `_tool/discover` in the
  container's probe. So this batch needs no exception list and leaves
  nothing legacy behind.
- **The deletion is fmt-, check- and lint-clean**: trialled on
  `_build/**` (12 files, 43 lines) — `fmt: PASS (547 files)`,
  `check: PASS`, `lint: PASS`. Deleting the call line leaves the blank
  line that followed it, so no reflow rides along.

## Change

In every `*_test.tl` under this batch's scope, delete each line
matching exactly `^test_[A-Za-z0-9_]*()$` — a bare call at column 1,
no arguments. Nothing else changes in those files, and no file outside
the scope is touched.

The edit is mechanical; do it with a throwaway script run from the
repo root, kept OUT of the tree (a `*.tl` inside it joins the build
graph):

```
grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _build _docs _types 3p _fuzz _eval _perf _tool | xargs sed -i -E '/^test_[A-Za-z0-9_]*\(\)$/d'
```

If a ratchet gate complains, run exactly the regen command its failure
message prints and commit the result — never weaken a gate another
way.

## Non-goals

No semantic edits ride along: no renames, no assertion changes, no
test added or removed, no reflow, no comment rewrites. No file outside
this batch's scope — the other six batches are file-disjoint on
purpose and two of them must never touch one file. No change to
`cosmic/test.tl`, `_tool/seam.tl`, `_tool/discover.tl`, or the
`call-after-define` lint (retiring it is 3IOCdvXF; it already passes
on a runner-mode file). No testrun or report change (3IOCdZCA). No pin
bump — that is 3IU62YqO, this item's blocker.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- No self-call survives in scope:
  `grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _build _docs _types 3p _fuzz _eval _perf _tool | xargs grep -c '^test_[A-Za-z0-9_]*()$' | grep -v ':0$'`
  prints nothing (and the `ls`/`grep` selection still names the files,
  so an empty selection is a bug, not a pass).
- The diff is deletions only:
  `git diff origin/main --numstat -- '*_test.tl' | awk '{a+=$1} END {print a+0}'`
  → `0` insertions.
- `bin/cosmic --make test` passes, and its summary still reports the
  same number of test files as before the edit.

## Enablement

none needed — the one blocker cleared. 3IU62YqO landed as #1450, so
`bin/cosmic.pin` now names `2026-08-27-cb39b65`, whose checker carries
the D29 seam (#1446's merge `7b9f0749` is an ancestor of that tag).
That is what `_build/coldbuild_test.tl` type-checks against, and it is
the gate this batch has to clear.

Re-measured at refine against `origin/main` at `cb39b65d` and later:
the selection command still names 73 files carrying 481 self-call
lines, unchanged from the Evidence above, so nothing there needs
refreshing.
