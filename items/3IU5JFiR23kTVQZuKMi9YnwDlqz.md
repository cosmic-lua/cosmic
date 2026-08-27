## Goal

Batch 1 of the all-runner migration (parent: 3IOCdooE): every
`cosmic/**` test file is `runner` mode — the self-call lines are
gone, and D29's seam runs the cases from the generated tail.

## Evidence

Measured 2026-08-27 at main (post-#1446, the compile seam):

- `git ls-files 'cosmic/*_test.tl' 'cosmic/**/*_test.tl' | wc -l`
  → 137 files; `grep -h "^test_" $(git ls-files 'cosmic/*_test.tl'
  'cosmic/**/*_test.tl') | wc -l` → their self-call lines (re-measure
  at pull; tree total was 2,943 across 259 files).
- The seam is all-or-nothing per file (D29, `_tool/discover.tl:8-19`):
  every case self-called = `legacy`, none = `runner`; a `test_*` name
  referenced anywhere else (passed, indexed, aliased) keeps the file
  legacy — such a file is LEFT UNTOUCHED and listed in the PR body.
- The convention line is a bare `test_<name>()` on the line directly
  after its function's closing `end` (AGENTS.md's current wording);
  that adjacency is what makes the deletion mechanical.

## Change

One commit, deletions only in `cosmic/**/*_test.tl`: for each
`local function test_<name>` in a file, delete the later line that is
exactly `test_<name>()` (trailing whitespace tolerated, nothing
else). A file where any `test_*` deletion candidate does not match
that exact shape, or where a `test_*` name appears in any non-call
position, is skipped whole and named in the PR body as left-legacy.
Scripting the walk is fine (the discovery lexer or a line scan);
committing the script is not part of this slice.

## Non-goals

No semantic edits, no helper/Example changes, no reordering, no
formatting fixes riding along. No AGENTS.md wording change (batch 3
owns the prose flip). Other directories untouched.

## Acceptance

- Before the edit, record `bin/cosmic --make test cosmic | tail -3`'s
  check count; after, the same command reports the SAME number of
  test functions run and `test: PASS`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -h "^test_" $(git ls-files 'cosmic/*_test.tl'
  'cosmic/**/*_test.tl') | wc -l` → 0, or exactly the calls of files
  the PR body lists as left-legacy.
- `git diff --numstat origin/main` shows only `cosmic/**/*_test.tl`
  rows, 0 additions each (pure deletions), except `.cosmic-coverage`
  if and only if the ratchet asked.

## Enablement

PULL-TIME GATE (the cold-build rule's third face): the pinned
release must carry the compile seam, or the pinned binary compiles a
runner-mode file with no tail and its tests silently never run under
any pinned-fallback path.
`git merge-base --is-ancestor 7b9f0749 <sha of the tag
bin/cosmic.pin names>` must hold — at refinement (2026-08-27 ~04:50Z)
it does NOT (pin 2026-08-27-6b88a0d, tag 6b88a0db, predates #1446's
04:40Z merge); the 06:00Z cron release plus its pin bump opens this.
Bounce rather than building if the gate fails; never dispatch a
release to force it.
