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

## Findings (2026-08-22, main `aaf4af95`)

**Headline: 42 of the 82 sites are removable today, 40 are still
genuine gaps.** Half the bucket was mis-sized by the census's stale
narrowing rules; the epic's remaining upstream-first backlog is 40
sites, not 86.

### How it was measured

A throwaway worktree at main `aaf4af95` (`git worktree add … origin/main`),
`--make fetch && --make build`, then per site: delete the `as` cast and
its `-- cast:` marker, run `bin/cosmic --check types <file>`, restore.
Clean ⇒ removable-now, refused ⇒ still a gap. Then every removable
site was applied AT ONCE in one worktree and the tree checked as a
whole:

```
bin/cosmic --make check   →  check: PASS (513 files)
bin/cosmic --make lint    →  lint: PASS (605 files)
bin/cosmic --make fmt     →  fmt: PASS (513 files)
git grep -h -o -E -- '-- cast: [^(]*' -- '*.tl' | wc -l   →  444 before, 402 after
```

A second pass re-tested all refused sites WITH the 37 removals applied:
**0 additional sites came clean**, so the classification does not
cascade and the two follow-up waves can land in either order.

### The population, restated

```
git grep -h -o -E -- '-- cast: [^(]*' -- '*.tl' | sed 's/-- cast: //' \
  | sort | uniq -c | sort -rn
```

returns **126 distinct reasons over 444 sites** at `aaf4af95` (this
spec previously said 127 / 439; the 444 is what the command returns
today and is the number the tables below reconcile against).
Intersected with the #1114 comment's 48 `narrowing-gap` reason
strings, the bucket is **82 sites** (86 at the census, `07cf57f`).
The four-site drop:

| reason | census | today | why |
|---|---:|---:|---|
| `pcall result` | 3 | 0 | wave 6a (#1290) deleted them |
| `narrowed by named` | 2 | 0 | the `_tool/doc` index-model wave (#1197 / #1206) typed the model |
| `record union after guard` | 4 | 3 | one site's surrounding code changed |
| `CompressFormat's word set nests inside DecompressFormat's` | 2 | 3 | `_fuzz/compress_fuzz_test.tl:75` added since |
| `table implements the Reader interface` | 1 | 2 | `_fuzz/sse_fuzz_test.tl:118` added since |

### Sub-family totals, re-measured

| # | sub-family | spec said | today | removable | blocked |
|---|---|---:|---:|---:|---:|
| 1 | terminal-call gap (narrowing-gap rows only) | 24 | 20 | **10** | 10 |
| 1b | …plus the 4 `function shape (…)` binding-boundary rows | — | 4 | 0 | 4 |
| 2 | `pcall` returns | 7 | 7 | **4** | 3 |
| 3 | `or` fallback | 7 | 7 | **1** | 6 |
| 4 | record fields | 7 | 7 | **3** | 4 |
| 5 | Teal generics | 5 | 5 | **0** | 5 |
| 6 | setmetatable-built records | 10 | 10 | **7** | 3 |
| 7 | the remaining singletons | 21 | 26 | **17** | 9 |
| | **narrowing-gap total** | 81 | **82** | **42** | **40** |

Movement against the spec's stated 24 / 7 / 7 / 7 / 5 / 10:

- family 1 is **20**, not 24, once the `function shape (…)`
  parenthetical rows are excluded — those four are the census's
  `binding-boundary` bucket, listed separately as 1b. Counting them in
  (as the spec's enumeration did) gives 24.
- families 2–6 are unmoved.
- the singleton tail is 26, not 21, for the same reason the bucket is
  82 rather than 81: two `narrowing-gap` reasons went to zero and two
  gained a site in `_fuzz/`.

### The `function shape` split, by `file:line`

The grep separates them without judgment: the parenthetical variant
captures as `function shape ` (trailing space).

**`narrowing-gap` — 15 sites, bare `-- cast: function shape`:**

```
removable (10)                       blocked (5)
  _cli/require_hints.tl:237            cosmic/check_assertions_test.tl:382
  cmd/cosmic/main.tl:467               cosmic/coverage/init.tl:162
  cosmic/coverage/init_test.tl:23      cosmic/quicksand/init.tl:73
  cosmic/fetch/init.tl:381             cosmic/quicksand/proxy.tl:144
  cosmic/fetch/init.tl:382             cosmic/quicksand/proxy.tl:145
  cosmic/fetch/init.tl:419
  cosmic/fetch/init.tl:421
  cosmic/fetch/init.tl:423
  cosmic/fetch/init.tl:425
  cosmic/fetch/init.tl:427
```

**`binding-boundary` — 4 sites, `-- cast: function shape (…)`:**

```
cosmic/net/connect.tl:95   (unix-path overload, errno kept)
cosmic/net/socket.tl:333   (unix-path overload)
cosmic/net/socket.tl:396   (unix-path overload)
cosmic/net/socket.tl:436   (timeval overload)
```

All four were tested anyway and all four refuse deletion — the
binding declares one shape for an overloaded call
(`wrong number of arguments (given 2, expects 3)`,
`argument 2: got string, expected integer`). The census's bucket call
is confirmed by measurement.

### The 42 removable, and how

- **27 plain deletions** — the cast and its marker come out, nothing
  else changes.
- **1 with a companion deletion** — `cosmic/fs/dir_test.tl:49`: once
  the cast goes, `local fs_types = require("cosmic.fs.types")` is
  unused and warnings are errors, so the require goes with it.
- **4 via an `is`-guard restructure into the shape #1191 corrected** —
  `cosmic/_teal_ast.tl:54`, `cosmic/_teal_ast_test.tl:30`,
  `_types/tlast_test.tl:53`, `cosmic/searcher_tree_test.tl:40` all
  guard with `type(x) == "function"`, which does not narrow, and then
  cast. `x is function(A): (B, C)` (and `x is <named function-type
  alias>`) DOES narrow `any`, in both the early-exit and the
  `assert(...)` position. This is the single largest dividend of the
  #1191 correction in this bucket, and **nothing in
  `cosmic/teal_narrowing_test.tl` pins it** — the test covers
  primitives, records and arrays, not function types. Wave 6c carries
  the test case.
- **10 `function shape` sites** are wave 6b; the other 32 are wave 6c.

`cosmic/fetch/init.tl:220` is a **half-win** recorded here rather than
in a wave: the line carries two casts under one marker
(`setmetatable(fields as Response, response_mt) as Response`) and
EITHER one alone can go — deleting both fails
(`argument 1: got {string : <any type>}, expected Response`). The site
still needs a cast, so it counts as blocked.

### Follow-up wave items

| cluster | sites | item |
|---|---:|---|
| `function shape` (one reason string, one cause) | 10 | `3IFUa4AY` — cast wave 6b |
| everything else verified removable | 32 | `3IFUaiGA` — cast wave 6c |

Both are filed unparented (as captures) because `plan` was 44/12 at
the time; each names `3HyRcW05` (the cast epic) as its attach target in
its own prose. There is no third cluster: after 6b, the largest
remaining sub-family of removables is setmetatable-built records at 7,
below the 8-site floor, which is why 6c is one item rather than five.

### The 40 that stay blocked, and the limit each names

`pinned?` is whether `cosmic/teal_narrowing_test.tl` already holds the
fact. Where it does not, the follow-up item that would need it is
named — this is the input to the D5 upstream-first backlog.

| limit | sites | pinned? |
|---|---|---|
| **error-terminated guard does not narrow** — `if x == nil then error(…) end` leaves `T \| nil` below. | `cosmic/check.tl:268`, `cosmic/searcher.tl:97`, `cosmic/searcher.tl:233` | **yes** — `test_error_terminated_guard_does_not_narrow` |
| **terminal-call gap (`unix.exit`)** — same class, but the terminator is a binding call the checker cannot see is terminal. | `cosmic/fs/walk.tl:88`, `cosmic/quicksand/box/run.tl:211`, `cosmic/quicksand/proxy.tl:141,142,144,145` | no — same family as the pinned `error(…)` case; a `unix.exit` variant belongs beside it |
| **`or` fallback keeps the nil in the union** — `(f() or {})` stays `Found \| nil`, `(f() or "")` stays `string \| nil`. | `_cli/build/init_test.tl:72,144,169`, `_cli/build/steps.tl:279`, `_make/imports.tl:181`, `_make/root.tl:67` | no |
| **record FIELDS do not narrow** — documented in AGENTS.md, untested. | `_make/stage.tl:163`, `_perf/perf_test.tl:31` | no |
| **untyped calls yield no declarable extra slots** — declaring a third slot off `pcall` yields "assignment in declaration did not produce an initial value"; `pcall(f)` on a `function()` yields only `boolean`; a call on a value typed `any` yields one `any`. | `cosmic/shm.tl:145,170`, `cosmic/check_assertions_test.tl:382`, `cosmic/quicksand/init.tl:73`, `_cli/main_handlers.tl:64`, `cosmic/searcher_test.tl:57` | no |
| **Teal generics cannot index, `pairs`, or return-as `T`** — `cannot index key 'body' in variable 'opts' of type T`, `cannot apply pairs on values of type: T`. | `cosmic/fetch/extras.tl:184,199,202,239`, `cosmic/fs/walk.tl:146` | no |
| **`setmetatable({}, mt)` cannot produce a record** — `setmetatable` is `function<T>(T, metatable<T>): T`, so the seed table must already BE the record. | `cosmic/sqlite/row_iter.tl:64`, `cosmic/fetch/init.tl:220`, `cosmic/signal.tl:291` | no |
| **Teal has no enum subtyping** — `CompressFormat is not a DecompressFormat` though the word set nests. | `cosmic/compress_test.tl:24,37`, `_fuzz/compress_fuzz_test.tl:75` | no |
| **an inequality guard does not narrow an enum** — `f ~= "auto"` leaves `DecompressFormat`. | `cosmic/compress_test.tl:151` | no |
| **a union arm does not narrow from a correlated success guard** — the tuple case (`rem_ns` is `integer \| string` past `rem_s ~= nil`) and the record-union case. | `cosmic/time.tl:88`, `_perf/bench/micro_bench.tl:191`, `cosmic/re.tl:199` | no |
| **a handler union does not narrow to the callable arm.** | `cosmic/signal.tl:250` | no |
| **a declared arity is not an overload** — `debug.sethook` is declared with required arguments, so a zero-argument call refuses. | `cosmic/coverage/init.tl:162` | n/a — `_types/gentl.tl`'s tl-stdlib extraction, not a narrowing limit |
| **binding overload declarations** — one declared shape for an overloaded C call. (Census bucket `binding-boundary`, outside the 82; measured here to record the `function shape` split.) | `cosmic/net/connect.tl:95`, `cosmic/net/socket.tl:333,396,436` | n/a — upstream `definitions.lua` |

The rows sum to 40 (the four `net/*` sites are the separate
`binding-boundary` bucket). The two largest still-blocked families are
the **terminal-call gap (6, plus 3 in its pinned `error(…)` sibling)**
and **untyped calls (6)**; between them they are 30% of what remains.
Both are tl-side, and both are what a `3p/tl/tl_patch.tl` change would
have to buy — sized, now, at 12 sites rather than the 31 the stale
classification implied.

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

## Review (2026-08-22, session `sched-l2q1e4`) — accepted

Re-run independently in a throwaway worktree at main `aaf4af95`
(`--make fetch && --make build`).

**Population, recomputed.** `git grep -h -o -E -- '-- cast: [^(]*' --
'*.tl' | wc -l` → **444**; piped through `sed`/`sort -u` → **126**
distinct reasons. Both match.

**Sub-family totals, recomputed by reason string.** Families 2–6 are
confirmed unmoved at 7 / 7 / 7 / 5 / 10, site for site. The
`function shape` split is confirmed exactly: 15 bare
`-- cast: function shape` (narrowing-gap) and 4 parenthetical
`function shape (…)` (binding-boundary, the four `cosmic/net/*` sites),
plus 1 `function shape from map view`.

**The 82 as a partition.** The 40 blocked (enumerated in the limits
table above), the 10 of wave 6b, and the 32 of wave 6c were assembled
into one list: **82 lines, 0 duplicates, and every one lands on a real
`-- cast:` marker in the tree.** The classification is a genuine
partition of 82 distinct existing sites, and 42 + 40 = 82 closes.

**Spot-checks (4, all confirming).**

| site | claim | result |
|---|---|---|
| `_cli/require_hints.tl:237` | removable | cast deleted → `Type check passed` |
| `cosmic/fetch/init.tl:419` | removable | cast deleted → `Type check passed` |
| `cosmic/coverage/init.tl:162` | blocked | refuses, with exactly the named limit: `wrong number of arguments (given 0, expects at least 2 and at most 3 or at least 3 and at most 4)` |
| `cosmic/_teal_ast.tl:54` | removable via `is`-guard restructure | guard replaced with `thaw is function({string: any}): (any, any)`, cast deleted → `Type check passed` |

The last is the headline dividend of #1191 and it holds: `is` on a
function type narrows `any` past an early-exit guard. Confirmed too
that `cosmic/teal_narrowing_test.tl` does **not** pin it — its five
cases are `test_typevar_union_is_not_truthiness_narrowed`,
`test_boolean_union_is_not_truthiness_narrowed`,
`test_bare_any_does_not_satisfy_a_typed_parameter`,
`test_early_exit_is_guard_narrows` (primitives, records, arrays) and
`test_error_terminated_guard_does_not_narrow`. Wave 6c carrying that
test case is the right call.

**Follow-ups exist and are sized as recorded**: `3IFUa4AY` (6b, 10
sites) and `3IFUaiGA` (6c, 27 plain + 1 companion + 4 restructures =
32). Both name `3HyRcW05` as their attach target in their own prose.

**One correction, to the census-drop table only.** Its
`record union after guard  4 → 3` row does not hold, and its stated
cause ("one site's surrounding code changed") misattributes it. What
happened is the same grep artifact the findings handle explicitly for
`function shape`: `cosmic/quicksand/box/run.tl:211` gained a `(die)`
parenthetical in #1211 (`git log -S 'record union after guard (die)'`,
2026-08-16), so the BARE reason string counts 3 today while the site
count is still 4. The tables above count all four — family 1 is 20
only with `box/run.tl:211` in it — so the `86 → 82` arithmetic is off
by one against them. Nothing actionable moves: the site is classified
blocked either way, both follow-up waves are unaffected, and the
partition check above shows no site is missing or double-counted. Read
the 82 / 42 / 40 as the measured numbers and the `86 → 82`
reconciliation as approximate to ±1.

Accepted: every stated acceptance bullet passes, and every material
claim spot-checked came back as recorded.
