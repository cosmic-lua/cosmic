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

Blocked on 3IU62YqO (bump `bin/cosmic.pin` to a release carrying the
D29 compile seam). Measured: with the current pin,
`_build/coldbuild_test.tl` fails on any runner-mode file — the pinned
release's checker predates the seam, so build generation 1 sees an
uncalled local. Nothing else is needed; the seam itself landed as
#1446.
