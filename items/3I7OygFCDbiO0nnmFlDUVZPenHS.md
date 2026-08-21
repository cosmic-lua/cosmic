## Goal

G3 — the cast epic's wave 6, the re-measure the epic itself mandates:
the census classified 86 sites as `narrowing-gap` against the
documented narrowing limits, and one of those limits was since measured
FALSE (#1191: early-exit `is` guards DO narrow — the correction landed
with `cosmic/teal_narrowing_test.tl` pinning the real behavior). An
unknown share of the 86 is therefore removable today with no tl patch
at all, and every wave planned on the stale classification is
mis-sized until this runs.

## Where the census is

The classification this item re-measures is the **accepted comment on
whilp/cosmic issue #1114** (taken at `07cf57f`, 549 sites / 129 distinct
reasons). Its `narrowing-gap` bucket is 86 sites across 48 distinct
reason strings — the table's `bucket` column is the only place that
mapping exists, so read it there rather than re-deriving it. The five
sub-families the epic names ("terminal-call gap 21, `pcall` returns 10,
`or` fallback 7, record fields 5, Teal generics 7") come from that
comment's "Suggested wave order" section and are prose groupings, not
reason strings; the enumeration below replaces them with strings.

## What wave 6a already settled

3I9TqfLm (PR #1290, accepted, merged) ran exactly this method — delete
the cast, `--check types`, keep the deletion only if clean — over four
reason strings: `pcall result`, `or fallback does not narrow`, `tuple
element`, `record union after guard`. Its 22 sites are now 16, so six
were removable and were deleted. Two things carry forward:

- `pcall result` is now **0 sites** in the tree; do not re-test it.
- `tuple element` is bucketed `removable-now` by the census, NOT
  `narrowing-gap`, so 6a spanned two buckets. Its 8 surviving sites
  (`cosmic/time.tl`, `cosmic/re.tl`,
  `cosmic/quicksand/proxy/rules_test.tl`) are checker-confirmed
  un-removable and out of scope here.

Everything else in the 48-string bucket is untested against the
corrected rules. That is this item's population.

## Change

A measured re-classification, worked in a throwaway worktree against a
built binary (the wave-3 slice's method: delete, check, record).

**The population, enumerated 2026-08-21 at main `aaf4af95`.** The whole
bucket is 81 sites today (86 at the census). The command that produces
today's reason→count table:

```
git grep -h -o -E -- "-- cast: [^(]*" -- '*.tl' | sed 's/-- cast: //' \
  | sort | uniq -c | sort -rn
```

It returns 127 distinct reasons over 439 sites; intersect it with the
#1114 table's `narrowing-gap` rows to get the 81. Six sub-families are
enumerated below by reason string and `file:line`, measured with
`git grep -n -o -E -- "-- cast: .*" -- '*.tl'` at the same commit. They
cover 60 of the 81; the remaining 21 are singleton reasons the same
grep lists.

1. **terminal-call gap — 24 sites** (`function shape` 19, `record union
   after guard` 4, `function shape from map view` 1). NOTE: the census
   splits `function shape` into 15 `narrowing-gap` and 4
   `binding-boundary` by the parenthetical variant (`-- cast: function
   shape (…)`); `cosmic/net/socket.tl:333` is the representative of the
   binding-boundary four. Separating them by line is the first thing
   this slice does, and its result is part of the deliverable.
   ```
   _cli/require_hints.tl:237       cosmic/fetch/init.tl:425
   cmd/cosmic/main.tl:467          cosmic/fetch/init.tl:427
   cosmic/check_assertions_test.tl:382   cosmic/net/connect.tl:95
   cosmic/coverage/init.tl:162     cosmic/net/socket.tl:333
   cosmic/coverage/init_test.tl:23 cosmic/net/socket.tl:396
   cosmic/fetch/init.tl:381        cosmic/net/socket.tl:436
   cosmic/fetch/init.tl:382        cosmic/quicksand/init.tl:73
   cosmic/fetch/init.tl:419        cosmic/quicksand/proxy.tl:144
   cosmic/fetch/init.tl:421        cosmic/quicksand/proxy.tl:145
   cosmic/fetch/init.tl:423
   record union after guard: cosmic/check.tl:268, cosmic/fs/walk.tl:88,
     cosmic/quicksand/box/run.tl:211, cosmic/quicksand/proxy.tl:141
   function shape from map view: cosmic/quicksand/proxy.tl:142
   ```
   (6a already tested the four `record union after guard` sites and
   confirmed them un-removable; re-test them only if a `function shape`
   deletion in the same file changes the shape around them.)
2. **`pcall` returns — 7 sites** (census said 10): `pcall variadic
   returns to tuple` `cosmic/shm.tl:145,170`; `pcall variadic returns`
   `cosmic/sqlite/extras.tl:57`; `pcall multi-return shape`
   `cosmic/sqlite/extras.tl:99`; the parenthetical `from any (…)`
   `_cli/main_handlers.tl:64`, `cosmic/searcher.tl:76`,
   `cosmic/shm.tl:220`.
3. **`or` fallback — 7 sites**: `or fallback does not narrow`
   `_cli/build/init_test.tl:72,144,169`; `scalar fallback`
   `_cli/build/steps.tl:271,279`; `or keeps the nil union`
   `_make/root.tl:67`; `` `or` keeps the nil in the union ``
   `_make/imports.tl:181`. (6a tested the first three and kept them.)
4. **record fields — 7 sites**: `set whenever ok`
   `cosmic/_script_cache.tl:217`; `a graph verb has one`
   `_make/stage.tl:193`; `a graph verb always has one`
   `_make/stage.tl:163`; `a graph verb always has a target (…)`
   `_make/stage.tl:196`; `nil ruled out by the guard above`
   `cosmic/searcher.tl:97,233`; `narrowed by the nil guard above`
   `_perf/perf_test.tl:31`.
5. **Teal generics — 5 sites**, all but one in `cosmic/fetch/extras.tl`:
   `:184` (`generic T via mirror record`), `:199` (`generic T as map to
   copy`), `:202` (`copied map as mirror record`), `:239` (`copied map
   back to generic T`), plus `cosmic/fs/walk.tl:146` (`fresh table as
   generic T`).
6. **setmetatable-built records — 10 sites**, a family the epic's prose
   groupings omit: `table seeded as record` `cosmic/fetch/body.tl:143`,
   `cosmic/fetch/init.tl:220`, `cosmic/fs/find.tl:295`,
   `cosmic/sqlite/row_iter.tl:64`, `cosmic/zip.tl:189`; `partial table
   into record` `cosmic/ip.tl:97,240`; `__index method table as record`
   `cosmic/ip.tl:87,232`; `record built incrementally`
   `cosmic/signal.tl:291`.

**The method, per site.** Delete the `as` cast and its `-- cast:`
comment in a throwaway worktree, run `bin/cosmic --check types <file>`,
and classify: clean ⇒ `removable-now`, refused ⇒ still a genuine gap.
Never weaken the guard or restructure surrounding code to force a clean
check — restructuring INTO a shape `cosmic/teal_narrowing_test.tl`
already pins as narrowing is allowed and is the point; anything else is
not. Confirm the final worktree state with `bin/cosmic --make check`
before recording, so no site is called removable on a file that does
not check as a whole. Revert the worktree; nothing lands from here.

**The deliverable, written back into THIS item's spec**: the
re-classified table (per sub-family: still-blocked vs removable-now,
with counts and the commands that produced them, dated and at a named
commit), plus one filed follow-up wave item per removable cluster ≥ 8
sites — enumerated sites, pre-verified deletions, expected floor delta,
in the wave-3 shape. File them as captures (`gitboard new` with no
parent) when `plan` is at limit, with the attach target named in the
capture's own prose.

**What stays blocked gets its limit named precisely**: which tl
behavior refuses, and whether `cosmic/teal_narrowing_test.tl` already
pins it. A limit NOT pinned there gets a test case written into the
follow-up item that would need it. That list is the D5 upstream-first
backlog's input.

## Non-goals

- no cast deletions land from this slice — verification happens in a
  throwaway worktree; the deletions are the follow-up waves' diffs.
- no tl patch work (`3p/tl/tl_patch.tl`) — this slice only names what
  a patch would buy, sized by measurement.
- no re-testing of 3I9TqfLm's `tuple element` sites (a different bucket)
  or of `pcall result` (0 sites remain).
- `_build/casts_baseline.tl` is not regenerated here: nothing is
  deleted, so nothing moves the floor.

## Acceptance

A research slice, reviewed per review.md's research clause:

- this item's spec carries the re-classified table, every count beside
  the command that produced it, dated and at a named commit.
- the six sub-family totals above are restated as of the research
  commit, and any that moved from 24 / 7 / 7 / 7 / 5 / 10 is explained.
- the `function shape` split (how many of the 19 are the census's
  `narrowing-gap` 15 and how many the `binding-boundary` 4) is recorded
  by `file:line`.
- each `removable-now` cluster ≥ 8 sites has a filed follow-up item id
  recorded here.
- the reviewer re-runs at least the sub-family totals with the grep
  above and spot-checks two removable claims by deleting those casts
  and running `bin/cosmic --check types <file>`.

## Enablement

none needed — the method is wave 3's and wave 6a's, twice proven on
this epic; the census's location is named above; the population is
enumerated by `file:line` at a named commit; and the narrowing facts to
test against are pinned in `cosmic/teal_narrowing_test.tl`.
