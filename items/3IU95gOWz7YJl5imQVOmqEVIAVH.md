## Goal

The closer of the runner-mode migration (parent: 3IOCdooE): once the
seven deletion batches have landed, the tree is proven all-runner and
the prose that taught the self-call convention teaches D29 instead. No
file is left saying a test runs because it calls itself.

Salvaged from 3IU5Jn4h, which owned this half of the work before its
series was retired in favour of the seven-batch cut — its deletion
scope is now batch 1/7's, and only this half was left unowned.

## Evidence (measured 2026-08-27; re-measure at pull)

- **Prose teaching the old convention.** `AGENTS.md`'s bullet "test
  files call each test where they define it: a `test_*` function in a
  `_test.tl` is called on the line after its `end`, so a failing run
  names the function." Sweep for the rest at pull:
  `grep -rn "line after its" docs/ skills/ AGENTS.md`.
- **The end-state check.** `grep -h '^test_[A-Za-z0-9_]*()$'
  $(git ls-files '*_test.tl') | wc -l` → 2,946 today, tree-wide across
  275 files. After the seven batches it must be 0.
- **Nothing is expected to be left legacy.** Deleting every self-call
  line and re-classifying with `_tool/discover` leaves 0 of 275 files
  in `legacy` or `mixed` — measured with the probe in 3IOCdooE's
  container spec. If a batch's PR did leave a file legacy, this item's
  end-state count is that file's calls rather than 0, and each such
  file is named here with its reason.
- **`cosmic/test.tl` and `_tool/discover.tl` are the contract** the
  new prose describes: a file is all-or-nothing, every case
  self-called is `legacy`, none is `runner`, and a mix is refused.

## Change

1. `AGENTS.md`: replace the "test files call each test where they
   define it" bullet with D29's rule — a `test_*` function in a
   `_test.tl` runs because the toolchain found it; the compile seam
   appends a generated tail that calls every case in source order; a
   self-call is the legacy mode and is on its way out (3IOCdvXF).
2. Whatever else the `grep -rn "line after its" docs/ skills/
   AGENTS.md` sweep names at pull, in the same commit — each rewritten
   to the same rule, not deleted.
3. Nothing else. If the end-state count is not 0, do NOT delete the
   remaining calls here: that is the owning batch's bug, and it goes
   back to that item.

## Non-goals

No source edits — every `*_test.tl` deletion belongs to one of the
seven batches (3IU6AZEx, 3IU6AgNN, 3IU6AsZC, 3IU6B7LD, 3IU6BPFg,
3IU6BiCH, 3IU6BjUI), and this item's diff touches no `.tl` file. No
lint retirement and no legacy-mode removal — that is 3IOCdvXF, which
waits on a release shipping dual mode. No change to `cosmic/test.tl`,
`_tool/seam.tl` or `_tool/discover.tl`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- THE END STATE: `grep -h '^test_[A-Za-z0-9_]*()$' $(git ls-files
  '*_test.tl') | wc -l` → `0`, or exactly the calls of the files a
  batch PR named as left-legacy, each named in this PR body with its
  reason.
- `grep -n "call each test where they define it" AGENTS.md` → no
  match.
- `grep -rn "line after its" docs/ skills/ AGENTS.md` → no match.
- `git diff --name-only origin/main` prints only prose files: no
  `*.tl` path appears.

## Enablement

Blocked on all seven deletion batches. Until they land the end-state
count cannot be 0 and the prose would describe a tree that does not
exist yet.
