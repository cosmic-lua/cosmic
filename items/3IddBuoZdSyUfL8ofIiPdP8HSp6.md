## Goal

The runner-mode migration (D29, container 3IOCdooE) deleted every
top-level `test_*()` self-call from the tree's `*_test.tl` files across
seven batches, each scoped by directory. Found 2026-08-30 while
building the container's closer (mqEV_IAVH/3IU95gOW): five files added
or rewritten in ordinary feature PRs AFTER their owning batch had
already merged carry the same self-call shape the batches were meant
to erase tree-wide, so the closer's end-state check
(`grep -h '^test_[A-Za-z0-9_]*()$' $(git ls-files '*_test.tl') | wc -l`
→ must be `0`) cannot pass until these are migrated too. This is drift,
not a batch bug — none of the five files existed (in this shape) when
their directory's batch ran.

## Evidence (measured 2026-08-30 against origin/main ce897b1e)

- **21 self-call lines across 5 files**, all top-level, one call
  directly after its function's `end` (the same legacy shape every
  batch deleted):

  ```
  $ for f in _build/cast_sites_test.tl _build/nil_returns_test.tl _perf/baserun_test.tl _perf/skew_test.tl _perf/tiebreak_test.tl; do echo "$f: $(grep -c '^test_[A-Za-z0-9_]*()$' "$f")"; done
  _build/cast_sites_test.tl: 3
  _build/nil_returns_test.tl: 2
  _perf/baserun_test.tl: 6
  _perf/skew_test.tl: 1
  _perf/tiebreak_test.tl: 9
  ```

  Re-run at pull; the tree grows, so a moved number is drift to refresh
  in place, not a reason to bounce.
- **All 5 postdate their directory's batch.** Batch 1/7 (3IU6AZEx,
  merged, PR #1458) covered `_build/` and `_perf/` and left them clean
  at merge time. `git log --follow` on each of the 5 files shows they
  were added or rewritten afterward, in ordinary feature PRs — #1510
  (`cast_sites_test.tl`), #1471 (`nil_returns_test.tl`), #1480/#1490
  (`baserun_test.tl`, `skew_test.tl`), #1498 (`tiebreak_test.tl`) — none
  of which is a batch PR, and no board item claims any of the 5 as
  deliberately left legacy.
- **Every self-call is the plain shape**, no fixture wrapping, no
  string-literal false positive: `grep -n '^local function test_\|
  ^test_[A-Za-z0-9_]*()$' <file>` on each of the 5 shows every call
  sitting directly on the line after its own function's `end`, matching
  the exact deletion shape the seven batches applied.
- **No cast-site or ratchet side effect.** None of the 5 files has a
  real `as` cast (`grep -n ' as ' <file>` on each hits only English
  prose inside strings/comments — verified by reading every hit), so
  no `docs/design/cast-sites.tsv` update rides along, unlike several of
  the seven batches.
- **This closes the drift, not just this instance**: after this PR,
  `grep -h '^test_[A-Za-z0-9_]*()$' $(git ls-files '*_test.tl') | wc -l`
  on the whole tree drops by exactly these 21 (re-run the container
  closer's own end-state command at pull to confirm no further drift
  landed meanwhile).

## Change

In exactly these 5 files, delete each line matching exactly
`^test_[A-Za-z0-9_]*()$` — a bare call at column 1, no arguments:

```
grep -l '^test_[A-Za-z0-9_]*()$' _build/cast_sites_test.tl _build/nil_returns_test.tl _perf/baserun_test.tl _perf/skew_test.tl _perf/tiebreak_test.tl | xargs sed -i -E '/^test_[A-Za-z0-9_]*\(\)$/d'
```

Nothing else changes in those files, and no file outside this list is
touched. If a ratchet gate complains (none is expected per the Evidence
above, but if the tree has moved), run exactly the regen command its
failure message prints and commit the result — never weaken a gate
another way.

## Non-goals

No semantic edits ride along: no renames, no assertion changes, no
test added or removed, no reflow, no comment rewrites. No file outside
the 5 named. No change to `cosmic/test.tl`, `_tool/seam.tl`,
`_tool/discover.tl`, or the `call-after-define` lint. No testrun or
report change. No pin bump. This item does not itself flip
`AGENTS.md`'s prose or verify the tree-wide end state at 0 — that is
mqEV_IAVH/3IU95gOW, blocked on this item; do not fold its scope in
here.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- No self-call survives in the 5 files:
  `grep -c '^test_[A-Za-z0-9_]*()$' _build/cast_sites_test.tl _build/nil_returns_test.tl _perf/baserun_test.tl _perf/skew_test.tl _perf/tiebreak_test.tl | grep -v ':0$'`
  prints nothing.
- The diff is deletions only, exactly 21 lines, across exactly these
  5 files: `git diff origin/main --numstat -- _build/cast_sites_test.tl _build/nil_returns_test.tl _perf/baserun_test.tl _perf/skew_test.tl _perf/tiebreak_test.tl` sums to 0 insertions, 21 deletions, and `git diff --name-only origin/main` names no other file.
- `bin/cosmic --make test` passes, and its summary reports the same
  number of test files as before the edit (this migration doesn't add
  or remove a test FILE, only a self-call line).

## Enablement

None needed — the five files, their exact self-call counts, and the
absence of any cast-site side effect are all measured above. Once this
lands, mqEV_IAVH (the container closer) is unblocked: re-run its own
end-state grep to confirm 0 before building it, in case more drift
landed between this item and that pull.
