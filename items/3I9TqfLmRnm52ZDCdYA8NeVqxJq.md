## Goal

G3 — an honest type layer, no escape hatches (docs/goals.md), via the epic "measure
and drive down the as-cast count" (board item 3HyArM3A). This is wave 6's own
prerequisite step, from that epic's wave plan: "Re-measure this class first: the
census counted [narrowing-gap] against the documented narrowing limits, and one of
those limits (early-exit `is`) is measured false — #1191 landed the correction, so
some of the 86 may already be removable with no patch at all."

## Change

Every site in the tree tagged with one of the four `narrowing-gap`-family reason
strings, measured 2026-08-19 (`git grep -n -- "-- cast: pcall result\|-- cast: or
fallback does not narrow\|-- cast: tuple element\|-- cast: record union after guard"
-- "*.tl"`, 22 lines across 12 files):

```
_build/dupes.tl:135, 143                          (tuple element)
_cli/build/init_test.tl:72, 144, 169              (or fallback does not narrow)
_eval/score_test.tl:66                            (pcall result)
_perf/bench/re_bench.tl:73                        (record union after guard)
cosmic/check.tl:268                               (record union after guard)
cosmic/fs/walk.tl:88                              (record union after guard)
cosmic/literal_test.tl:138, 162, 172              (pcall result)
cosmic/quicksand/box/run.tl:211                   (record union after guard)
cosmic/quicksand/proxy.tl:141                     (record union after guard)
cosmic/quicksand/proxy/rules_test.tl:57           (tuple element)
cosmic/re.tl:285, 316                             (tuple element)
cosmic/time.tl:132, 136, 138, 162, 166, 168       (tuple element)
```

For each site: read the guard immediately above the cast, and try removing the `as`
cast (and its trailing/leading `-- cast:` comment) while keeping the guard as-is or
restructuring it into the corrected narrowing shape documented in
`cosmic/teal_narrowing_test.tl` and AGENTS.md's "Narrowing nil unions" section
(`if not (x is T) then return/error(...) end` narrows on `return`, not on `error`;
`assert(x)` narrows as an expression; `x and x.field` narrows). Run `bin/cosmic
--check types <file>` after each edit.

- If the file now checks clean without the cast, the site is `removable-now`: keep the
  deletion, and delete the site's line from `_build/casts_baseline.tl` count for that
  file by regenerating (see Acceptance).
- If the checker still refuses without the cast, the site is a genuine narrowing gap:
  revert the file to its original cast + comment, unchanged. Do not weaken the guard
  or restructure the surrounding code to force a false positive — a site that still
  needs the cast stays exactly as it is today.

Do not touch any site outside the 22 listed above, even one carrying a similar reason
string discovered while editing a file in the list (e.g. a second `tuple element` site
in a file already on the list IS in scope only if it appears in the line list above;
one that turns up elsewhere is out of scope — file it as a new capture instead).

## Non-goals

- No `3p/tl/tl_patch.tl` changes and no upstream `tl` proposal — this slice is a
  re-classification against the ALREADY-corrected narrowing rules (#1191), not new
  narrowing capability. A site that needs a patch to be removable is confirmed
  un-removable today and stays out of scope for a future, separately-sized wave.
- No change to `cosmic/teal_narrowing_test.tl` or AGENTS.md/docs/guides/checking.md —
  #1191 already corrected those; this slice does not touch narrowing documentation.
- No change to any file's logic beyond deleting a cast and its comment — a site that
  "almost" checks clean except for an unrelated nearby issue is left with its cast
  intact, not partially refactored.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- For every site actually deleted, run `bin/cosmic --make run _build/casts.tl
  --baseline` to regenerate `_build/casts_baseline.tl`, then confirm the ratchet
  tightened: `grep -oE '= [0-9]+' _build/casts_baseline.tl | awk '{s+=$2} END {print
  s}'` prints a number strictly below today's 445.
- The PR description states, per file, how many of that file's listed sites were
  removed vs. kept (e.g. "cosmic/time.tl: 6 listed, 2 removed, 4 kept — the tuple
  element cast on a `nil`-narrowed multi-return still has no expression-level guard").
- `git grep -c -- "-- cast:" -- "*.tl" | awk -F: '{s+=$NF} END {print s}'` after the
  change matches the new `_build/casts_baseline.tl` total exactly (the tree and the
  gate never drift — `TREES` already covers every listed file).

## Enablement

none needed — the corrected narrowing rules are already documented in
`cosmic/teal_narrowing_test.tl` and AGENTS.md; this slice applies them, it does not
discover new ones. `bin/cosmic --check types <file>` is the existing gate command.
