## Goal

G3 — an honest type layer. One file-disjoint piece of the parent's
library latent-nil sweep (3IPXQuYu): the census sites where a `T | nil`
reaches a non-nil sink with **no guard anywhere**, so the fix is a
judgment at each site rather than a mechanical wrap. These are the
census's real finds and the last thing standing between the tree and a
strict nil-flow mode.

## Change

Re-run the census's Method and take every row under `_eval/` and
`_docs/`. For each, choose between the two mechanisms the census names
— a guard at the site, or an honest signature — and apply it. Record
the choice per file in the PR.

**Measured 2026-08-26** from the committed pre-rules census
(`awk -F'\t' '$1 !~ /_test\.tl$|_example\.tl$|_benchmark\.tl$/ && $1 ~ /^(_eval|_docs)\//' docs/design/nil-flow-sites.tsv`):
**43 rows in 10 files** — `_eval/` 30 rows in 8 files (heaviest
`_eval/checks/json-cli.tl` 8), `_docs/` 13 rows in 2 files. The four
narrowing rules (PR #1383, landed `57dda9bd`) closed part of that;
re-run the scan at pull and write the number into the PR.

These two trees are grouped because both are single-purpose internal
harnesses with few files and dense counts, and because neither is
touched by the other pieces.

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
