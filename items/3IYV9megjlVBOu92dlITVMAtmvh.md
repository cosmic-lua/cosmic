## Evidence

A slice that files a capture almost always files it against the tree the
slice is BUILDING, not the tree on `main`. The capture's spec then cites a
file, a line, a section or a count that exists only on an unmerged branch —
and nothing records the dependency, so `next` offers the item as unblocked
and a builder pulling it finds the evidence missing.

Measured 2026-08-28. Three instances in one session, 17 items:

**1. Fifteen items minted by `3IYDxqM8` (PR #1489).** Each cites a
`### <class>` section of `docs/design/casts.md` and the per-site list
`docs/design/cast-sites.tsv`. On `origin/main` that document carries only
the 7 from-any classes and the TSV does not exist:

```
$ git show origin/main:docs/design/casts.md | grep -c '^###'          → 7
$ git show refs/pull/1489/head:docs/design/casts.md | grep -c '^###'   → 21
$ git ls-tree origin/main docs/design/ --name-only | grep cast-sites   → (nothing)
```

None of the 15 recorded a blocker. All were repaired by hand.

**2. `3IYT8Bpm`, minted by `3IYPq8Sx` (PR #1491).** Its fix changes the
recognizer in `_cli/citations.tl`, which #1491 rewrites, and its one tree
exemplar survives on `main` alone:

```
$ git show origin/main:docs/design/casts.md        | grep -c 'cosmic/json.tl:155' → 1
$ git show refs/pull/1491/head:docs/design/casts.md | grep -c 'cosmic/json.tl:155' → 0
$ git show refs/pull/1489/head:docs/design/casts.md | grep -c 'cosmic/json.tl:155' → 0
```

**3. `3IYTD6Mm`, minted by the same slice.** It measures "13 of 15 rules
documented" and #1491 changes both halves:

```
$ git show origin/main:docs/guides/lint.md         | grep -c '^## ' → 13
$ git show refs/pull/1491/head:docs/guides/lint.md | grep -c '^## ' → 14
```

## The sharp part

`3IYTD6Mm`'s own spec NAMES `3IYPq8Sx` in prose — "`3IYPq8Sx` adds
`doc-citation`; `reads-declaration` remains". The author knew. What is
missing is not the knowledge but the EDGE: `next` reads `blocked_by`, not
prose, so an accurately-described dependency that was never recorded is
invisible to every ordering decision the board makes.

That is what makes this a system defect rather than three careless
filings. `SKILL.md` tells a session finding something out of scope to
`gitboard new "title" --spec-file F` and return to the slice — and says
nothing about the fact that F was written against a branch. The path of
least effort produces an unblocked item citing unmerged evidence, every
time.

## Not asserted here

Whether the fix is a `--blocked-by` flag on `new` (cheap, still opt-in),
a `new` run from inside a slice defaulting to blocking on that slice's
item (automatic, but wrong for genuinely independent findings), a
ready-bar check that refuses a spec citing a path absent from `main`
(catches it later but catches everything), or a skill-level instruction
in the capture paragraph (no enforcement). They trade differently and the
choice is `plan`'s.

The 17 items above are already repaired, so this item is about the next
seventeen.
