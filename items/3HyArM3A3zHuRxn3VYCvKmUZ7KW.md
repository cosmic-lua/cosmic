Imported from whilp/cosmic#1112.


## Goal

G3 — an honest type layer, no escape hatches (docs/goals.md). This epic is the first
milestone toward its win condition (zero `as` casts): make the cast count measured,
classified, and moving down.

## Outcome (observable)

- CI ratchets per-file `as`-cast counts against a committed baseline: a PR that adds a
  cast fails a gate; a PR that removes casts tightens the committed floor.
  **Ratchet hole closed 2026-08-18** (wave S6, #3I5waWwq / PR #1276): `_build/casts.tl`'s
  `TREES` now covers `_eval/` and `_fuzz/`; the gated count and the tree count are
  measured equal below.
- Every existing cast site is classified by removal strategy, so each follow-up wave is
  a concrete, sized slice. The classification is the census on #1114 (549 sites as of
  2026-08-15); the current count is below.
- The first removal wave has landed and the ratcheted total is strictly below the
  census's 549.

## Where the count stands (measured 2026-08-19)

The gated number is whatever `_build/casts.tl` counts — its `TREES` constant is the
definition, not an ad-hoc directory list — and it is exactly the committed floor:

```
$ grep -oE '= [0-9]+' _build/casts_baseline.tl | awk '{s+=$2; n++} END {print s, n}'
445 132

$ git grep -c -- "-- cast:" -- "*.tl" | awk -F: '{s+=$NF} END {print s}'
445
```

445 gated across 132 files, 445 in the tree — the two now match exactly; the
`TREES` hole wave S6 fixed no longer exists.

**Wave 1 (#1192), the `_tool/doc` index model (#1197), and wave 3 (checker-verified
fixture deletions, #3I7BSkD7 / PR #1281, floor 455 -> 443 at the time) have all
landed.** Against the 2026-08-15 census of 549, the tree has come down substantially
and the gated floor has tightened with every wave.

## Evidence (2026-08-15 survey; census 2026-08-15 on #1114)

The census (the accepted comment on #1114) classified all 549 sites (547 real casts —
2 are `_cli/lint.tl` quoting its own marker syntax): `removable-now` 298,
`narrowing-gap` 86, `binding-boundary` 57, `inherent` 56, `needs-helper` 52. More than
half sit behind the one reason string `from any`, of which two groups were
single-decision waves: `_perf`'s Scenario record typed over `any` (59 sites) and
`_tool/doc`'s index model passed as `{string: any}` (43 sites) — both landed.

The classification's totals have moved a lot since 2026-08-15; a wave filed against
this census's original counts must re-measure before writing its Change section, not
carry the 2026-08-15 numbers forward. Wave 4's retirement below is the worked example
of why.

## Children

- [x] #1113 — cast ratchet: per-file counts gated against a committed baseline (merged, PR #1138)
- [x] #1114 — cast census: classify every site by removal strategy (accepted)
- [x] #1115 — fs.octal: one typed octal parser, the 21-site octal family removed (merged, PR #1154)
- [x] #1191 — early-exit `is` guards DO narrow: correct the stale caveat (merged, PR #1194 / `0300aba`)
- [x] #1197 — `_tool/doc` index casts: type the model as `ModuleDoc`, 47 sites (merged, PR #1206 / `2f362af`)
- [x] #1192 — `_perf` bench casts: 51 `from any` sites become `is` guards (merged, PR #1195 / `6831dcc`)
- [x] 3I5FXjke — traps_test.tl/time_test.tl transition scaffolds, 21 -> 1 (wave 0.5, PR #1267)
- [x] 3I5waWwq — close the ratchet hole: `_eval`/`_fuzz` join `TREES` (wave S6, PR #1276)
- [x] 3I7BSkD7 — wave 3: delete the 12 checker-verified fixture casts, floor 455 -> 443 (PR #1281)
- [ ] 3I9TqfLm — wave 6a: re-measure `narrowing-gap` against the corrected #1191 rules, delete what checks clean (filed 2026-08-19, ready)

## Wave plan (from the census — file as WIP slots open, in this order)

0.5. ~~Transition scaffolds — 20 pure deletions, two test files (S1).~~ **DONE**,
   #3I5FXjke, PR #1267.

1. ~~`_perf` Scenario generics — 59 sites, one type change in `_perf/perf_types.tl`~~
   **Retired 2026-08-16, measured.** A generic `Scenario` cannot express what
   `BenchModule.scenarios()` returns: the list holds differently-typed scenarios, and
   the checker refuses `{Scenario}` given a `Scenario`
   (`type parameter <>: got StateA, expected `). The 51 in-scope
   sites in `_perf/bench/*_bench.tl` are `res`/context narrowings, not one state-type
   change, and they come out with `is` guards and NO type change — that is #1192. The
   remaining 9 `_perf/*.tl` sites (module-loading and JSON boundaries) are a separate,
   later wave. Do not re-attempt the generic.

2. `_tool/doc` index model — **DONE. #1197, merged as PR #1206 (`2f362af`).** 47 sites
   became 1: `_tool/doc/index_test.tl:38` — `return (data as DecodedIndex).modules`, a
   decode boundary. Fold it into a later `from any` wave, not a slice of its own.

3. Verified leftovers — **DONE. #3I7BSkD7, PR #1281.** 12 checker-verified deletions,
   floor 455 -> 443 at the time (re-measured above: 445 gated today, after wave S6
   widened `TREES`).

4. ~~`to_integer` — the honest `integer | nil, string` parser for the runtime
   number->integer family (~37 hex/decimal/`%d` sites)~~ **Retired 2026-08-19,
   measured.** Every current `-- cast: number to integer` site (`git grep -n -- "--
   cast: number to integer" -- "*.tl"`, 12 lines) and every hex/decimal `as integer`
   site (`cosmic/literal.tl:76,108`, `cosmic/url.tl:54`) already follows the
   verify-then-cast idiom `fs.octal.tl` established: the string is regex-captured as
   pure digits/hex before the cast, or explicitly bound-checked
   (`cosmic/literal.tl`'s `\u{}` codepoint site). These are `inherent`, not a removable
   gap — there is no shared-parser wave left to file here. The `%d`-format sites in
   `_tool/coverage/lines.tl` and `cosmic/quicksand/proxy/serve.tl` are narrowing a
   `number` field that is a `_types/gentl.tl`-generated tl `Error.y`/`.x` widening —
   that is wave 5 (`binding-boundary`), not this one. Looking past the tagged sites
   for genuinely-unverified runtime parses turned up a real but DIFFERENT, untagged
   defect (`math.tointeger(tonumber(x))` is unsoundly typed non-nilable at 9 sites) —
   filed as capture 3I9Tko2h, not sized as a slice yet; it needs its own design
   decision before it is ready (see that item).

5. `binding-boundary` (57) — one annotation pass on whilp/cosmopolitan's
   `definitions.lua` + `_types/gentl.tl` widenings. whilp/cosmopolitan has no gitboard
   of its own (its AGENTS.md tracks only `perf`-labeled GitHub issues) — filing this
   wave means opening a GitHub issue/PR there directly, not a board item here, or a
   board item whose Acceptance names the upstream PR. Not yet filed.

6. `narrowing-gap` (86 at the 2026-08-15 census). **Wave 6a (re-measurement) is filed
   as 3I9TqfLm, ready.** It covers the 22 sites the tree carries today under the four
   `narrowing-gap` reason strings (`pcall result`, `or fallback does not narrow`,
   `tuple element`, `record union after guard`) — down from the census's original
   estimate, most of the shrinkage from wave 1/2/3 touching files that also carried
   narrowing-gap sites. The remaining upstream-first backlog items (terminal-call gap,
   generics) are not yet re-measured against #1191 and stay unfiled until 3I9TqfLm
   reports what is left.

7. ~~Close the ratchet hole (S6).~~ **DONE.** #3I5waWwq, PR #1276.

## What the tree actually does, measured 2026-08-16

Probed against the local build with a control (bare `any` into a typed parameter
fails, so the passes are the guard's doing):

- `if not (x is T) then return … end` **narrows** below the guard — for `string`,
  `integer`, `number`, a record, `{string}`, `{any}`, `{{string: any}}`.
- `if not (x is T) then error(…) end` does NOT narrow.
- `is` cannot be applied to a FIELD at all: `can only use 'is' on variables`. Copy to
  a local first.

AGENTS.md, `docs/guides/checking.md` and `docs/guides/gotchas.md` stated the first of
these backwards; #1191 corrected them and pinned all three behaviours in
`cosmic/teal_narrowing_test.tl`.

The middle rule is a live constraint on wave sequencing: a guard that ends in
`error(...)` does not narrow, so the ~28 `from any` sites in decode-boundary TESTS
(`cosmic/json_test.tl` 10, `cosmic/deep_test.tl` 8, `cosmic/literal_test.tl` 8,
`cosmic/deep_example.tl` 5) have no idiom available today. That family needs an
enablement slice before it is a wave; do not file it as ordinary removal work.

## The G3 wording decision (before the win condition is enforced)

`inherent` (56 sites) is the floor the census implies: metatable identity, deliberate
stdlib patching, deliberate-invalid-input tests, dual-shape params, removed-surface
probes. G3's literal "zero casts" needs those to become something other than casts, or
the goal to name the justified-and-classified floor as the exception. That is a goals.md
amendment PR, owned by a planner, due before wave 6 completes — not a slice.


---
_Generated by [Claude Code](https://claude.ai/code)_

## Outcome verified, epic closed 2026-08-19

All three Outcome bullets hold, measured on main at `e22805d` (wave 6a's
merge):

- The ratchet is live and was exercised by wave 6a itself: PR #1290
  tightened `_build/casts_baseline.tl` 445 -> 438, and the tree count
  matches the floor exactly (`git grep -c -- "-- cast:" -- "*.tl"` sums
  to 438).
- Every site is classified (census #1114, re-measured per wave above).
- Multiple removal waves have landed; 438 is strictly below the census's
  549.

Wave 6a's report (PR #1290), which this epic was holding wave-6
follow-ups for: of the 23 narrowing-gap-family sites, 7 deleted, 16
confirmed genuine, in three classes —

1. guards ending in `error(...)`/a terminal helper (`die`, `unix.exit`)
   do not narrow (cosmic/check.tl, cosmic/fs/walk.tl,
   cosmic/quicksand/box/run.tl, cosmic/quicksand/proxy.tl) — the
   terminal-call gap; needs a tl patch or upstream work, an enablement
   slice, never ordinary removal.
2. correlated multi-return tuples (cosmic/re.tl, cosmic/time.tl 8
   sites) — one local's type conditional on another's nil-ness; not
   expressible in tl today.
3. `any`/unnarrowed unions into strictly-typed params
   (_cli/build/init_test.tl, cosmic/quicksand/proxy/rules_test.tl).

What remains toward G3, for the root (3HyRcW05) to drive as fresh
milestones — deliberately NOT filed as children here, plan being over
limit and each needing its own sizing:

- wave 5, `binding-boundary` (57 at census): an annotation pass on
  whilp/cosmopolitan's `definitions.lua` + `_types/gentl.tl` widenings;
  cross-repo — the board's `repo:` field (in flight on PR #1286) is the
  vehicle.
- wave 6b: the 16 confirmed narrowing gaps above, upstream-first.
- the `from any` decode-boundary test family (~28 sites), blocked on the
  terminal-call narrowing gap (class 1) — enablement before wave.
- the G3 wording decision: `inherent` (56) vs the literal "zero casts"
  win condition — a goals.md amendment owned by a planner, due before
  any wave-6b work completes.
