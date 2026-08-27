## Goal

Batch 3 (the closer) of the all-runner migration (parent: 3IOCdooE): every remaining
test file (`_eval/`, `_perf/`, `_fuzz/`, `_docs/`, `3p/`) is
`runner` mode, the tree ends all-runner, and the prose that taught
the self-call convention now teaches D29's runner.

## Evidence

Measured 2026-08-27 at main (post-#1446, the compile seam):

- File counts at capture: _eval 31, _perf 10, _fuzz 9, _types were
  batch 2's; 3p 2, _docs 1 → 53 files (re-measure at pull; tree
  total was 2,943 self-calls across 259 files).
- Prose teaching the old convention: AGENTS.md's "test files call
  each test where they define it" bullet; sweep
  `grep -rn "line after its" docs/ skills/ AGENTS.md` at pull for
  others.
- The seam is all-or-nothing per file (D29, `_tool/discover.tl:8-19`):
  every case self-called = `legacy`, none = `runner`; a `test_*` name
  referenced anywhere else (passed, indexed, aliased) keeps the file
  legacy — such a file is LEFT UNTOUCHED and listed in the PR body.
- The convention line is a bare `test_<name>()` on the line directly
  after its function's closing `end` (AGENTS.md's current wording);
  that adjacency is what makes the deletion mechanical.

## Change

One commit: the same mechanical deletion over the remaining trees'
`*_test.tl` files, PLUS the prose flip — AGENTS.md's convention
bullet now states D29 (a test runs because it is defined; the
generated tail runs it; a self-call is legacy), and any other prose
the Evidence sweep found follows. A 3p test file that is vendored
rather than ours stays legacy and is named. For each
`local function test_<name>` in a file, delete the later line that is
exactly `test_<name>()` (trailing whitespace tolerated, nothing
else). A file where any `test_*` deletion candidate does not match
that exact shape, or where a `test_*` name appears in any non-call
position, is skipped whole and named in the PR body as left-legacy.
Scripting the walk is fine (the discovery lexer or a line scan);
committing the script is not part of this slice.

## Non-goals

No semantic edits, no helper/Example changes, no reordering, no
formatting fixes riding along. Batches 1 and 2's directories
untouched (they landed first — this is the closer).

## Acceptance

- Before the edit, record `bin/cosmic --make test | tail -3`'s (the whole tree)
  check count; after, the same command reports the SAME number of
  test functions run and `test: PASS`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- THE END STATE: `grep -h "^test_" $(git ls-files '*_test.tl') |
  wc -l` → 0 tree-wide, or exactly the calls of files any batch's PR
  listed as left-legacy (each named in this PR body with its reason).
- `grep -n "call each test where they define it" AGENTS.md` → no
  match (the wording flipped).
- `git diff --name-only origin/main` shows only the remaining
  trees' `*_test.tl` files, the prose files the sweep named, and
  `.cosmic-coverage` if and only if the ratchet asked.

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
release to force it. Also gated on batches 1 and 2 having landed
(block edges on the board).
