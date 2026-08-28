## Goal

G3 — an honest type layer. `docs/design/cast-sites.tsv` is the map G3's
remaining work is planned from: thirteen of the fifteen items minted
under this root tell their implementer to filter it on a class to get
their site list. A map nothing checks stops being evidence the first
time the tree moves, and it has already moved.

## Problem

The inventory drifted within twenty minutes of landing, and no gate
noticed.

`3IYDxqM8` (#1489) added the 214-row inventory. `3IYAOXUC` (#1490)
then removed all five casts from `_perf/run.tl` and
`_perf/bench/literal_bench.tl` and regenerated `_build/casts_baseline.tl`.
Measured on `origin/main` `71e7d312`, with both merged:

```
$ git show origin/main:_build/casts_baseline.tl \
    | awk -F'= ' '/\] = /{gsub(/,/,"",$2); s+=$2} END {print s}'
209
$ git show origin/main:docs/design/cast-sites.tsv | tail -n +2 | wc -l
214
$ git show origin/main:docs/design/cast-sites.tsv \
    | grep -cE '^_perf/(run|bench/literal_bench)\.tl'
5
```

Five rows name casts that no longer exist, in two files that now hold
none, and `--make ci` is green. It will stay green through every one of
the thirteen closure items, each of which lowers a baseline row and
leaves the inventory saying otherwise.

**Nothing reads the file.** Its only mentions in the tree are three
prose lines in the document beside it:

```
$ git grep -n 'cast-sites' origin/main
docs/design/casts.md:57
docs/design/casts.md:436
docs/design/casts.md:465
```

**The checks exist — they were run by hand, once.** #1489's Acceptance
carried exactly the commands that would have caught this, as manual
steps in a PR description rather than as a test:

```
tail -n +2 docs/design/cast-sites.tsv | wc -l          # vs the baseline sum
diff <(cut -f1 …| sort -u) <(baseline paths | sort -u)  # every path known
diff <(cut -f3 …| sort -u) <(sed -n 's/^### //p' …)     # classes vs headings
```

The first of those fails today. That is the whole defect: a ratchet's
worth of checking was written down and then not wired to anything.

**The per-file check is the one that matters.** Totals can agree while
the distribution is wrong; per-file counts cannot. This passed at
#1489's merge and fails now:

```
diff <(tail -n +2 docs/design/cast-sites.tsv | cut -f1 | sort | uniq -c \
        | awk '{print $2"\t"$1}' | sort) \
     <(sed -n 's/^  \["\(.*\)"\] = \([0-9]*\).*/\1\t\2/p' \
        _build/casts_baseline.tl | sort)
```

## Change

Wire the checks that already exist into a test, and repair the drift.

**1. Repair the inventory.** Drop the five rows for `_perf/run.tl` and
`_perf/bench/literal_bench.tl`; the file becomes 210 lines. Re-derive
rather than hand-edit — `_cli.lint.cast_lines(content, file)` returns a
file's real cast lines and is what #1489 extracted with — and reconcile
the affected per-class counts in `docs/design/casts.md` prose.

**2. Add the gate**, as a test beside the existing build ratchets. It
must assert, against the committed baseline and the committed document:

- per-file counts agree (the check above), which subsumes the total;
- every class in column 3 has a `### ` heading in `casts.md`, and every
  heading has at least one row;
- every row's line holds a real cast, by `_cli.lint.cast_lines` rather
  than by grepping for the word `as` — #1489's row check used the grep,
  which passes on any line containing `as` in prose.

Its failure message must name the regeneration command, the way the
cast baseline's own failure does, so a session that lowers a cast count
is told in one line how to update the map.

**3. Decide whether the file is generated or curated, and say so in
`casts.md`.** Columns 1 and 2 are derivable; column 3 is a human
judgment that cannot be regenerated. So a full `--baseline` regen would
destroy the classification. Name the intended workflow — most likely
regenerate paths and lines, preserve the class for a site that still
exists, and fail loudly for a site with no class — and state it where
the document explains the file.

## Non-goals

- **Close no cast, and change no baseline count.** This makes the map
  match the tree; it does not change the tree.
- **Do not reclassify.** Existing class assignments for sites that still
  exist are #1489's judgment and stand.
- **Do not touch `docs/goals.md`** or the floor question — that is
  `3IYMQz3o`.
- **Do not add the check to `_cli/lint.tl`** as a style rule. This is a
  ratchet over committed build state, which is `_build/`'s subject, not
  a per-file lint.
- Do not weaken `_build/casts_baseline.tl` or its regen command.

## Acceptance

- The new test FAILS against `origin/main` `71e7d312` (the drift is
  real), and passes after the repair. Quote both runs.
- `tail -n +2 docs/design/cast-sites.tsv | wc -l` equals the baseline
  sum, and the per-file diff above prints nothing and exits 0.
- Every row's line holds a cast by `cast_lines`, not by grep.
- `bin/cosmic --make ci` ends `ci: PASS`.
- Simulate the next closure: delete a cast from one `.tl`, regenerate
  the cast baseline, and show the new test failing with a message that
  names the regeneration command. Revert; nothing of that probe is
  committed.

## Evidence commands

```
git show origin/main:_build/casts_baseline.tl | awk -F'= ' '/\] = /{gsub(/,/,"",$2); s+=$2} END {print s}'
git show origin/main:docs/design/cast-sites.tsv | tail -n +2 | wc -l
git grep -n 'cast-sites' origin/main
```

Measured 2026-08-28 against `origin/main` `71e7d312`.
