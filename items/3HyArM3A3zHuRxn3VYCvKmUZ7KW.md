Imported from whilp/cosmic#1112.


## Goal

G3 — an honest type layer, no escape hatches (docs/goals.md). This epic is the first
milestone toward its win condition (zero `as` casts): make the cast count measured,
classified, and moving down.

## Outcome (observable)

- CI ratchets per-file `as`-cast counts against a committed baseline: a PR that adds a
  cast fails a gate; a PR that removes casts tightens the committed floor.
  **Known defect, measured 2026-08-17:** `_build/casts.tl`&#39;s `TREES` constant — the
  definition of what is gated — omits `_eval/` and `_fuzz/`, so 14 live casts sit
  outside the gate and can grow without limit. Until that is fixed, this outcome is
  measurably false for those two trees. See wave 7 (S6, to be filed).
- Every existing cast site is classified by removal strategy, so each follow-up wave is
  a concrete, sized slice. The classification is the census on #1114 (549 sites as of
  2026-08-15); the current count is below.
- The first removal wave has landed and the ratcheted total is strictly below the
  census&#39;s 549.

## Where the count stands (measured 2026-08-17, at `a3cd318`)

The gated number is whatever `_build/casts.tl` counts — its `TREES` constant is the
definition, not an ad-hoc directory list — and it is exactly the committed floor:

```
$ grep -oE &#39;= [0-9]+&#39; _build/casts_baseline.tl | awk &#39;{s+=$2; n++} END {print s, n}&#39;
445 132

$ git grep -c -- &#34;-- cast:&#34; -- &#34;*.tl&#34; | awk -F: &#39;{s+=$NF} END {print s}&#39;
459

$ git grep -c -- &#34;-- cast:&#34; -- &#34;*.tl&#34; \
    | grep -vE &#34;^(_build|_cli|_docs|_make|_perf|_tool|_types|_work|cmd|cosmic)/&#34; \
    | awk -F: &#39;{s+=$NF} END {print s}&#39;
14
```

445 gated across 132 files; 459 in the tree; the 14-site difference is the `TREES`
hole — `_eval/stage.tl` 9, `_eval/stage_test.tl` 3, `_fuzz/compress_fuzz_test.tl` 1,
`_fuzz/sse_fuzz_test.tl` 1, of which 12 are `from any`.

**Wave 1 (#1192) has landed** as PR #1195 (`6831dcc`), and it landed exactly on its
prediction: the previous pass at `3e15d15` measured 510 in the tree / 496 gated across
146 files and forecast &#34;510 -&gt; 459 and the floor 496 -&gt; 445&#34; when #1195 merged. Both
numbers are now measured at those values, so the forecast is closed rather than
carried. `_perf/bench` is down to its floor:

```
$ git grep -c -- &#34;-- cast:&#34; -- &#34;_perf/bench/*_bench.tl&#34; | awk -F: &#39;{s+=$NF} END {print s+0}&#39;
2
```

Against the 2026-08-15 census of 549, the tree has come down **90 sites (16.4%)**, and
the gated floor has tightened with every one of them.

## Evidence (2026-08-15 survey; census 2026-08-15 on #1114)

The census (the accepted comment on #1114) classified all 549 sites (547 real casts —
2 are `_cli/lint.tl` quoting its own marker syntax): `removable-now` 298,
`narrowing-gap` 86, `binding-boundary` 57, `inherent` 56, `needs-helper` 52. More than
half sit behind the one reason string `from any`, of which two groups are
single-decision waves: `_perf`&#39;s Scenario record typed over `any` (59 sites) and
`_tool/doc`&#39;s index model passed as `{string: any}` although `doc.ModuleDoc` exists
(43 sites).

The classification still holds; only the totals have moved. `from any` remains the
largest class by far — 240 sites, &gt;47% of the tree — and remains where the cheap wins
are.

## Children

- [x] #1113 — cast ratchet: per-file counts gated against a committed baseline (merged, PR #1138)
- [x] #1114 — cast census: classify every site by removal strategy (accepted)
- [x] #1115 — fs.octal: one typed octal parser, the 21-site octal family removed (merged, PR #1154)
- [x] #1191 — early-exit `is` guards DO narrow: correct the stale caveat (merged, PR #1194 / `0300aba`)
- [x] #1197 — `_tool/doc` index casts: type the model as `ModuleDoc`, 47 sites (merged, PR #1206 / `2f362af`)
- [x] #1192 — `_perf` bench casts: 51 `from any` sites become `is` guards (merged, PR #1195 / `6831dcc`)

## Wave plan (from the census — file as WIP slots open, in this order)

0.5. **Transition scaffolds — 20 pure deletions, two test files (S1, to be filed).**
   A file that reaches a module through `as {string: any}` because the surface it
   exercises was in flight is carrying dead scaffolding once that surface lands. Two
   remain, and both surfaces are landed and fully typed:
   `cosmic/fs/traps_test.tl` (19 casts -&gt; 1) and `cosmic/time_test.tl` (2 -&gt; 0), both
   re-measured at `a3cd318` and unchanged. All of
   `fs.copy_tree`, `fs.temp_file`, `TempFile.handle`/`.path`, `Dir:read`/`:close`,
   `fs.DT_DIR`/`fs.DT_REG` and `time.sleep_ms` are declared and were type-checked
   cast-free against the local build; the one survivor is `traps_test.tl`&#39;s
   `local fsa = fs as {string: any}`, which the removed-surface probes genuinely need
   (`fs.access` is a compile error — that is what those tests assert), and whose reason
   string becomes `probe removed surface`. Deletion only, no `is` guards, so it adds no
   unhit branches: #1201&#39;s coverage obstacle cannot reach it — `.cosmic-coverage` holds
   zero `_test.tl` rows. This retires the `signature transition` reason string from the
   tree (4 sites, both files). Cheapest remaining large win; take it before wave 3.

1. ~~`_perf` Scenario generics — 59 sites, one type change in `_perf/perf_types.tl`~~
   **Retired 2026-08-16, measured.** A generic `Scenario` cannot express what
   `BenchModule.scenarios()` returns: the list holds differently-typed scenarios, and
   the checker refuses `{Scenario}` given a `Scenario`
   (`type parameter &lt;&gt;: got StateA, expected `). The 51 in-scope
   sites in `_perf/bench/*_bench.tl` are `res`/context narrowings, not one state-type
   change, and they come out with `is` guards and NO type change — that is #1192. The
   remaining 9 `_perf/*.tl` sites (module-loading and JSON boundaries) are a separate,
   later wave. Do not re-attempt the generic.

2. `_tool/doc` index model — **DONE. #1197, merged as PR #1206 (`2f362af`).** 47 sites
   became 1. Unlike wave 1 this really was a type change: the model was already
   declared — `cosmic/doc/types.tl` has `ModuleDoc` and
   `DocIndex.modules: {string: ModuleDoc}` — and `_tool/doc/index.tl` simply passed it
   as `{string: any}`. Both dependencies on the untyped shape were settled in the
   slice: `merge_entries` indexed by a VARIABLE field name (a record cannot, so it
   became a generic over the element type), and the `exports` scratch field written
   onto entries and stripped again before the index shipped moved to a side map, with
   the strip pass deleted rather than typed around. The public record was not touched.
   One site survives, and is the intended floor for this tree:

   ```
   $ git grep -c -- &#34;-- cast:&#34; -- &#34;_tool/doc/*.tl&#34;
   _tool/doc/index_test.tl:1
   ```

   `_tool/doc/index_test.tl:38` — `return (data as DecodedIndex).modules`, a decode
   boundary. Fold it into a later `from any` wave, not a slice of its own.

3. Verified leftovers — `partial record fixture` (10, checker-verified deletable),
   enum rows (3), `a stub verb`/`partial literal` (2): ~15 pure deletions.

4. `to_integer` — the honest `integer | nil, string` parser for the runtime
   number-&gt;integer family (~37 hex/decimal/`%d` sites); NOT `math.tointeger`, whose tl
   declaration swallows nil (census §&#34;fine print&#34;).

5. `binding-boundary` (57) — one annotation pass on whilp/cosmopolitan&#39;s
   `definitions.lua` + `_types/gentl.tl` widenings; file against the cosmopolitan board.

6. `narrowing-gap` (86) — the D5 upstream-first backlog: terminal-call gap (21),
   `pcall` returns (10), `or` fallback (7), record fields (5), generics (7); each a
   `3p/tl/tl_patch.tl` or upstream-tl proposal. **Re-measure this class first**: the
   census counted it against the documented narrowing limits, and one of those limits
   (early-exit `is`) is measured false — #1191 landed the correction, so some of the 86
   may already be removable with no patch at all.

7. **Close the ratchet hole (S6, `work:enable`, to be filed).** Add `_eval` and `_fuzz`
   to `_build/casts.tl`&#39;s `TREES`, regenerate `_build/casts_baseline.tl`, and commit
   the 14 sites into the floor. One line plus a baseline regen. It must land as its own
   PR — never folded into a cast-removal slice, since a gate that lands inside the PR
   it polices proves nothing. Not ordered after wave 6; file it whenever a slot opens.

## What the tree actually does, measured 2026-08-16

Probed against the local build with a control (bare `any` into a typed parameter
fails, so the passes are the guard&#39;s doing):

- `if not (x is T) then return … end` **narrows** below the guard — for `string`,
  `integer`, `number`, a record, `{string}`, `{any}`, `{{string: any}}`.
- `if not (x is T) then error(…) end` does NOT narrow.
- `is` cannot be applied to a FIELD at all: `can only use &#39;is&#39; on variables`. Copy to
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
probes. G3&#39;s literal &#34;zero casts&#34; needs those to become something other than casts, or
the goal to name the justified-and-classified floor as the exception. That is a goals.md
amendment PR, owned by a planner, due before wave 6 completes — not a slice.


---
_Generated by [Claude Code](https://claude.ai/code)_