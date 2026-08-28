# Problem

G3 is measured by the total `as` cast count and its win condition is
zero. Measured on main 2026-08-28:

```
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l          # 225
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"  # 11
```

Four of those eleven are fixture text quoted inside test strings
(`_build/casts_test.tl`, `_cli/assert_lint_test.tl`,
`_tool/lint_test.tl`), so **7 real from-any sites remain and 218 sites
do not carry that reason**.

Every open cast item on the board is inside the from-any class:
`3IOK2cxG` ("close the 55 any-map field walk from-any sites", scoped
against the tree's 192 from-any sites at 2026-08-25), its child
`3IOmhR2S`, and the single open leaf `3IQCrJpB` (fetch's 3 dual-shape
binding-return sites). `docs/design/casts.md` — the only map — states
its own scope in its first sentence: it classifies the `from any`
reason and nothing else. So 218 of 225 sites sit outside the mapped
class and outside every open item, with the from-any container two
items from closing.

The last classification of that other population is the 2026-08-15
census (549 sites: `removable-now` 298, `narrowing-gap` 86,
`binding-boundary` 57, `inherent` 56, `needs-helper` 52), which the
epic `3HyArM3A` itself declares stale: "a wave filed against this
census's original counts must re-measure before writing its Change
section". The tree has since fallen 549 → 225 and the reason
vocabulary was rewritten by ten landed waves — 127 distinct reason
strings today, led by `userdata boundary` 22, `tuple element` 9,
`function shape` 9, `deliberate invalid input` 9, `the registry
defines it` 7, `record union after guard` 6:

```
git ls-files '*.tl' | xargs grep -ho -- "-- cast: .*" \
  | sed 's/-- cast: //; s/ *(.*//' | sort | uniq -c | sort -rn
```

`3HyArM3A`'s closing note ("Outcome verified, epic closed 2026-08-19")
names three successors "for the root (3HyRcW05) to drive as fresh
milestones — deliberately NOT filed as children here": wave 5
(`binding-boundary`, an annotation pass on whilp/cosmopolitan's
`definitions.lua` plus `_types/gentl.tl` widenings), wave 6b (the 16
confirmed genuine narrowing gaps, upstream-first), and "the G3 wording
decision: `inherent` (56) vs the literal 'zero casts' win condition — a
goals.md amendment owned by a planner, due before any wave-6b work
completes". The items later titled wave 6b/6c (`3IFUa4AY`,
`3IFUaiGA`, both landed 2026-08-23) are a different, narrower 6b —
verified-removable `function shape` and narrowing-gap deletions — not
the note's upstream-first residue. None of the three successors exists
as an open item: `gitboard find` over "zero casts", "cast count",
"goals.md amendment", "userdata boundary" and "inherent" returns only
done items and unrelated matches.

# The outcome

Every remaining cast is classified against today's tree, and each class
names either the mechanism that closes it or the reason it is a floor —
so the closure waves after from-any are mintable, and the wording
question (is G3's win condition literally zero, or zero plus a named,
justified floor) is answerable from measured evidence rather than from
the 2026-08-15 numbers.

The form is proven: `3IODJAjW` did exactly this for the from-any
subset — classify the population at a named commit, record for each
class what closes it, gather in one section the residue nothing closes,
and mint the closure slices — and `docs/design/casts.md` plus the eight
landed closure items are its output. `docs/design/nil-flow.md` is the
same shape for the sibling container.

This item is the outcome, not a slice. Refinement decides whether it is
one research pass over 225 sites or a container with a child per
family, and whether the wording decision is folded in or filed as its
own item under G3 once the residue is measured.
