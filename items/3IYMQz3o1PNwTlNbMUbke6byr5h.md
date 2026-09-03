## Evidence

Re-measured 2026-09-03 against `origin/main` (`96afd807`). The earlier
numbers (214 casts, 21 classes, 76 floor sites, 26 test probes) have
all moved:

    git show origin/main:docs/design/cast-sites.tsv | tail -n +2 | wc -l        → 191
    … | cut -f3 | sort -u | wc -l                                                → 20
    … | cut -f3 | sort | uniq -c | grep -E "probe|userdata|metatable|generic"
      14 type-defeating test probe   14 userdata boundary   5 runtime capability probe
      10 metatable access             8 generic T                          (sum 51)

`docs/design/casts.md` `## The floor` still says 71 — that prose is
not gated (`_build/cast_sites_test.tl` checks headings and rows, not
numbers). The compressed floor arithmetic — six wrap points, two probe
helpers, five probed shapes, two metatable helpers, eight generic
bodies — is unchanged at **23**, and the probe helpers already exist
(`cosmic/check.tl:137` `is_exposed`, `:120` `refuses`).

Candidate 3 can now be priced: `docs/design/cast-legality.md` landed
(#1589) with the gated rule in `3p/tl/tl_patch/cast.tl`
(`COSMIC_CAST_LEGALITY=1`) and a per-class table (`:60-80`): userdata
boundary 2 refused / 21 allowed, type-defeating test probe 12 / 2,
metatable access 6 / 4, generic T 4 / 4, numeric narrowing 9 / 0 —
its Method command re-run today gives the current join.

## Change

One decision by the goal owner, then one PR. Put the three wordings
in front of the owner with the numbers above (51 floor sites, 23 after
compression, the cast-legality refusal split), and land the answer:

- `docs/goals.md` G3 `measured by` / `win condition`: replace "zero
  `as` casts" with the chosen wording —
  1. literal zero, unchanged, with the sentence that the last 23 are
     reached by deleting what they serve;
  2. zero outside a declared floor, held per class in
     `docs/design/casts.md` and ratcheted per file by
     `_build/casts_baseline.tl`, test probes required to go through
     `check.is_exposed`/`check.refuses`;
  3. zero outside what the checker permits — `cast.tl`'s rule
     un-gated, `x as T` legal only from `any`, a `.d.tl` userdata, or
     the enclosing generic's type variable; refusals are the floor.
- `docs/design/casts.md` `## The floor`: rewrite the two counts to
  51 and the per-class split measured at merge time, keeping 23.
- Wording 3 additionally files (does not do) the un-gating work: one
  item per refused class from the census, blocked on a `bin/cosmic.pin`
  bump (a checker rule that refuses in-tree code is the cold-build
  case).
- `bin/cosmic --make ci` ends `ci: PASS` (`_build/docs_test.tl` and
  the doc-citation lint read both files).

## Non-goals

No cast is closed here and no baseline row moves; `er3p_REcx`'s
generic-T proof is independent and does not block this.
