## Goal

G3 — an honest type layer. One file-disjoint piece of the parent's
library latent-nil sweep (3IPXQuYu): the census sites where a `T | nil`
reaches a non-nil sink with **no guard anywhere**, so the fix is a
judgment at each site rather than a mechanical wrap. These are the
census's real finds and the last thing standing between the tree and a
strict nil-flow mode.

## Change

Re-run the census's Method and take every row under `_perf/`, `_cli/`,
`_tool/`, `_make/`, `_build/` and `cmd/`. For each, choose between the
two mechanisms the census names — a guard at the site, or an honest
signature — and apply it. Record the choice per file in the PR.

**Measured 2026-08-26** from the committed pre-rules census
(`awk -F'\t' '$1 !~ /_test\.tl$|_example\.tl$|_benchmark\.tl$/ && $1 ~ /^(_perf|_cli|_tool|_make|_build|cmd)\//' docs/design/nil-flow-sites.tsv`):
**47 rows in 25 files** — `_perf/` 12 in 8, `_cli/` 11 in 4, `_tool/`
10 in 4, `_make/` 8 in 5, `_build/` 3 in 2, `cmd/` 3 in 2. The four
narrowing rules (PR #1383, landed `57dda9bd`) closed part of that;
re-run the scan at pull and write the number into the PR.

The repo's own toolchain, grouped as one piece: no published API, and
`_cli/`, `_make/` and `_tool/` are the trees a `--make` change already
touches together, so keeping them in one diff is what keeps them
disjoint from everything else.

## Non-goals

- **No file outside this piece's tree.** The siblings own the rest;
  two diffs touching one file is the merge conflict this cut exists to
  avoid.
- **No `cosmic/time.tl`.** That file is board item 3IPXQcgW, with its
  own decided shape and its own blocker.
- **No `_test.tl`, `_example.tl` or `_benchmark.tl` file.** Those are
  the `check.must` sweep (3IPXQ1Zw and its children); a `check.must` in
  library code would throw and AGENTS.md forbids it.
- **No checker change.** `3p/tl/tl_patch.tl` and `_make/patch.tl` are
  untouched; this is edits at sites.
- **Do not widen a signature to `T | nil, string` without counting its
  callers.** A fallible return pushes the nil onto every call site;
  `grep -rn` the callers and record the count in the PR before choosing
  it over a guard.
- **Do not throw.** D23's exemption list is a rule, not an open
  licence: an `assert` is allowed only where the binding's declared
  `| nil` is unreachable for the arguments this call passes, and then
  it carries a trailing `-- assert: <why>` comment.
- **Do not add a cast.** `as` is not a fix for an unguarded union.
- **Do not rewrite `docs/design/nil-flow.md` or its `.tsv`.** They are
  a dated snapshot against `e7ac1580`; a later census re-derives them.
- **Do not commit the throwaway strict checker.** The Method builds it
  inside `o/` and deletes it; no edit to `o/3p/tl/tl.lua` rides with
  the PR.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS` (its coverage stage is what
  catches a guard that changed behaviour rather than only the type).
- Re-running the census's Method (`docs/design/nil-flow.md`,
  `## Method`) and filtering to this piece's tree reports **0**, or
  names each survivor and why it is not a real site.
- The same scan's total for every OTHER tree is unmoved from the
  pull-time baseline. Quote both numbers, before and after, in the PR.
- `git diff --name-only origin/main` lists only files in this piece's
  tree, and no `_test.tl` / `_example.tl` / `_benchmark.tl` file
  except one added to cover a behaviour a guard changed.

## Enablement

none needed. The site list comes from `docs/design/nil-flow.md`'s
`## Method`, re-run — the mechanisms the census names are in its
`## Mechanisms` section, and the throw rule is D23 as amended.

## Rework note (2026-08-31)

The prior review (review-sFqD_MI3z-w9p2) requested changes on two
points, from a bare `cosmic --check types` re-derivation of the strict
checker's verdict at `_perf/gate.tl`:

1. Claimed `_perf/compare.tl`'s `format` signature widening
   (`base?: pt.Results` → `base?: pt.Results | nil`) closes no real
   site, because an instrumented strict checker reported byte-identical
   argument-check output for the base and head versions of
   `_perf/compare.tl`.
2. Noted `_cli/main_handlers.tl`'s `handle_check_format` `if not code
   then` guard is not actually exercised by `--make ci`'s coverage
   stage, contrary to the Acceptance section's framing that coverage
   "catches a guard that changed behaviour."

The builder's rebuttal (PR #1578 comment 5473346169) traced finding 1
to a bare-invocation artifact: a `cosmic --check types <file>` with no
`--include-dir .` resolves a file's `require()`d modules through
whatever `o/bin/cosmic` binary is running its own already-built
`/zip/.tl/**` snapshot, not the live tree — invisible on the file named
on argv (`_perf/gate.tl`, always read from disk) but not on a module it
only reaches via `require` (`_perf/compare.tl`). This exact trap was
independently documented in `docs/design/nil-flow.md` by a separate,
unrelated PR (#1582, commit `ca6498896`) merged to main 4 minutes after
the request-changes review posted. No diff change was made; head sha
`3b47301` is unchanged throughout.

This review (review-sFqD_MI3z-1) independently reproduced the
mechanism from scratch, without reusing either side's strict two-hinge
checker: built a real `o/bin/cosmic` from this PR's head in a fresh
worktree (`bin/cosmic --make fetch && bin/cosmic --make ci`, `ci: PASS
(5 stages)`), then edited `_perf/compare.tl`'s `compare` record's
declared `format` parameter type to something the STANDARD
(unmodified, shipped) checker unambiguously rejects
(`deltas: string` in place of `deltas: {pt.Delta}`), leaving the
already-built binary untouched. A bare
`o/bin/cosmic --check types _perf/gate.tl` reported "Type check
passed" (silently resolving the binary's stale embedded
`/zip/.tl/_perf/compare.tl`); the identical command with
`--include-dir .` correctly reported
`_perf/gate.tl:154:24: error: argument 1: got {pt.Delta}, expected
string` — the exact call site (`print(compare.format(deltas, base,
cur))` in `print_report`) the PR's `compare.tl` fix touches. The file
was restored byte-for-byte afterward (diffed against the pre-edit
copy). This confirms finding 1's bare-invocation premise does not hold
for this file, and that the `format` signature widening is a real fix
for a genuine site, not a no-op — consistent with the builder's
originally-stated count of 24 sites in 15 (soon 16, counting
`compare.tl` itself once its own contributing call site in `gate.tl`
is attributed there) files, unchanged.

Finding 2 stands as accurate and non-blocking: the guard is defensive
(the state it handles is believed unreachable per `FormatResult`'s own
doc comment, `cosmic/format/init.tl:21`, "nil when ok is false — the
type admits it") and `--make ci`'s coverage stage does not exercise
that specific branch, the same shape as several other sites in this
diff. The builder acknowledged this directly in the rebuttal; no diff
change was requested for it.

Independently re-verified beyond the disputed finding, this pass:

- CI green (5/5 GitHub checks on head `3b47301`; a from-scratch
  `bin/cosmic --make ci` in my own fresh worktree also ends `ci: PASS
  (5 stages)`, 3068 tests passed, coverage ratchet ok).
- `git diff --name-only origin/main...HEAD` lists exactly the 16
  claimed files, all inside `_perf/ _cli/ _tool/ _make/ cmd/`
  (no `_build/` file — its one remaining flagged site,
  `_build/snippets_test.tl`, is a test file and out of this item's
  scope by the Non-goals; the other two pre-narrowing `_build/` sites,
  `casts.tl:67` and `size.tl:162`, are already closed on disk by the
  landed `and`/`or`-fallback narrowing rules — read directly, not
  assumed), none of them `_test.tl` / `_example.tl` / `_benchmark.tl`.
- No cast added, no throw added, `_make/patch.tl` and
  `3p/tl/tl_patch.tl` untouched, `docs/design/nil-flow.md` and its
  `.tsv` untouched, `cosmic/time.tl` untouched — all confirmed by
  `git diff` against `origin/main` returning zero lines for each.
- `compare.format`'s caller count (3: `_perf/run.tl`, `_perf/gate.tl`,
  `_perf/compare_test.tl`) confirmed complete by independent `grep -rn`.
- Mutation-tested `_make/stage.tl`'s new
  `if not target then return false, "not a graph verb" end` guard in
  isolation: confirmed the standard checker admits
  `target .. "-summary.txt"` for `target: string | nil` with no
  complaint (the exact hole this whole item closes), that an actual
  nil there crashes at runtime with a raw
  `attempt to concatenate a nil value` (an uncontrolled Lua error, not
  this project's `value, string` failure contract), and that the
  guard pattern this PR uses converts the same input into a clean
  `false, "not a graph verb"` return instead.
- Spot-checked several other in-scope guards against the invariants
  the PR body cites for them (`main_handlers.tl`'s `code` locals
  against `CompileResult`/`FormatResult`'s own "nil only when ok is
  false" doc comments; `_tool/coverage/report.tl`'s widened `exec`
  local; `_perf/peers/measure.tl` and `_perf/run.tl`'s
  `csys.nproc() or 0` against `cosmic/sys.tl`'s
  `nproc(): integer | nil, string` signature and
  `_perf/peers/report.tl`'s existing zero-as-unknown handling;
  `cmd/cosmic/embed_gen.tl`'s `EncodeLua(...) or "{}"` against the
  binding's OOM-only failure mode) and found each accurately described
  as a defensive, non-behaviour-changing fix, not a masked regression.

Verdict: accept.
