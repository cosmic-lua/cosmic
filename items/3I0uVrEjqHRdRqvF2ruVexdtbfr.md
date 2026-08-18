## Goal

Serves the ranked promise **#1 "no silent bugs"**, specifically its
"documented behavior is verified behavior" bullet (`docs/goals.md`):
*"every documented claim is executable — examples run as tests, coverage
ratchets, gates end in machine-readable verdicts... a doc statement that
is not CI-verified is a bug."* The coverage ratchet (`.cosmic-coverage` /
`_tool/coverage/`) is itself part of that verification chain — it is the
mechanism that is supposed to make "this line is covered" a checked
claim rather than an assumed one. This bug makes the ratchet's own
*denominator* silently wrong for at least one file, which is a silent
bug in the tool whose entire job is catching silent bugs.

(Checked the board's claim that this is "G6, hinted at as 'measured, not
inferred'": that phrase is real but lives in
`skills/work/decompose.md:126`, describing how a work-item SPEC must cite
measured facts — it is a spec-authoring rule, not a G6 restatement. G6
(`docs/goals.md`) is about performance on defining paths (startup,
`--check types` latency, embed build cycle) and does not fit this bug at
all. The correct goal citation is the "no silent bugs" promise above.)

## Change

**Root cause, confirmed by direct reproduction (not inferred):**
`_tool/coverage/report.tl`'s `normalize()` has two structurally similar
branches that map a collector chunk source back to a repo `.tl` file.
For a chunk loaded from inside a **built cosmic artifact's embedded
zip** (`@/zip/<module>.lua` — recorded whenever coverage-instrumented
code runs from a packaged binary rather than directly from the tree,
e.g. via `cosmic/script_test.tl`, which builds and execs binaries), the
branch resolves the correct **display** path (the `.tl` source) but
returns the **parse** path as the raw zip chunk string itself:

```
local zipped = p:match("^/zip/(.+)%.lua$")
if zipped then
  for _, source in ipairs({zipped .. ".tl", zipped .. "/init.tl"}) do
    if not is_excluded(source) and fs.is_file(source) then
      return source, p        -- BUG: p is "/zip/cosmic/fs/octal.lua"
    end
  end
  return nil
end
```

`analyze()` later does `fs.read(entry.parse)` and feeds the bytes to
`cov_lines.executable_lines()` (which calls `tl.lex`/`tl.parse_program`
and needs real Teal/Lua **text**). But `/zip/<module>.lua` inside a
running cosmic binary is **precompiled Lua bytecode**, not source text
(confirmed below) — or simply absent, depending on which binary is doing
the reading. Either way, static executable-line analysis fails, and
`analyze()`'s documented fallback ("the line universe is the statically
derived executable lines unioned with the lines actually hit") silently
degrades to **hits-only**, since the static half came back empty. The
reported "total" becomes however many *distinct lines happened to be
hit* under that one chunk identity — not the file's real executable-line
count.

Because `report.compute()`'s `merge_hits` sets `entry.parse` only on
the **first** `.cov` file seen for a given display path (iterating an
unordered directory scan across hundreds of parallel test-runner `.cov`
files), whichever chunk identity — the readable `o/<path>.lua` staged
copy, or the broken `/zip/<path>.lua` artifact copy — wins the race
determines whether a file's reported total is right or silently
collapsed. That race is exactly what makes the same `.tl` source
resolve to a different total-line count "depending on the measuring
environment": it depends on directory-scan order across a swarm of
`.cov` files from parallel subprocesses, which is not stable across
machines or runs.

`cosmic/fs/octal.tl` is the file that exposed it because it is a
2-line-body function whose only *other* executable lines are two
module-boilerplate lines (`local M = {...}` and `return M`) that never
register as "hit" under **any** chunk identity in the current test
suite (see Non-goals) — so when the bug's hits-only fallback fires, the
collapsed total (2) looks like a clean 100%-covered small file instead
of a visibly broken number, and nobody caught it.

**The fix:** in `_tool/coverage/report.tl`'s `normalize()`, in the
`/zip/` branch, return the already-resolved `.tl` source as the parse
target too, instead of the opaque zip chunk string:

```
      return source, source
```

(one line, the `for` loop just above it already guarantees `source` is
`fs.is_file`-readable Teal text — that's strictly better input for
`cov_lines.executable_lines` than the zip chunk path ever was, and it
makes the result **independent of merge order** by construction: no
matter which `.cov` file's chunk creates the entry first, `parse` is now
always the same real `.tl` path.)

Add a regression test to `_tool/coverage/report_test.tl`. The existing
`test_normalize_maps_embedded_directory_modules` (lines 72-78) already
covers `/zip/` chunk normalization but only asserts the first return
value (`display`); it never checks `parse`, which is exactly the blind
spot that let this ship. Extend it (or add a sibling test) to assert
the second return value too, e.g.:

```
local _, parse = report.normalize("@/zip/cosmic/url.lua", "")
assert(parse == "cosmic/url.tl", "got: " .. tostring(parse))
```

```facts
$ grep -n "cosmic/fs/octal.tl" .cosmic-coverage
182:cosmic/fs/octal.tl 2 2

$ git log --oneline -- _tool/coverage/lines.tl
905341a9 plan skill: two lanes — planners accept, implementers land (#1148)

$ git log --oneline --diff-filter=A -- cosmic/fs/octal.tl
9c7e2a80 fs.octal: one typed octal parser, twenty casts removed (#1154)

$ git log --oneline -- 3p/tl/tl_pin.tl
905341a9 plan skill: two lanes — planners accept, implementers land (#1148)

$ wc -l < _tool/coverage/report.tl
444

$ wc -l < _tool/coverage/report_test.tl
167

$ sed -n '/local zipped = p:match/,/^  end/p' _tool/coverage/report.tl
  local zipped = p:match("^/zip/(.+)%.lua$")
  if zipped then
    -- Two spellings, because the artifact FLATTENS directory modules:
    -- `require("cosmic.fs")` executes `/zip/cosmic/fs.lua`, compiled
    -- from `cosmic/fs/init.tl` -- there is no `cosmic/fs.tl` to find.
    -- Trying only the leaf spelling dropped every directory module in
    -- the tree, so each read as entirely uncovered and its floor went
    -- in at zero: the same "ratchet holds nothing" failure the mapping
    -- above exists to fix, for 14 of this repo's own modules.
    for _, source in ipairs({zipped .. ".tl", zipped .. "/init.tl"}) do
      if not is_excluded(source) and fs.is_file(source) then
        return source, p
      end
    end
    return nil
  end
```

Reference only — narrative, not machine-checked, since it depends on
building binaries and merging synthetic `.cov` fixtures rather than a
single repeatable shell one-liner; recorded here so the reasoning above
is traceable, not as an acceptance-gate fact. Static executable-line
analysis of `cosmic/fs/octal.tl`'s source directly
(`_tool.coverage.lines.executable_lines`) reports executable lines
22, 23, 26, 30 (total 4). The current, unpatched `normalize()` maps a
`/zip/` chunk `@/zip/cosmic/url.lua` to `display=cosmic/url.tl,
parse=/zip/cosmic/url.lua` — the bug being fixed. Isolated single-`.cov`
reproductions against the unpatched code: an `o/`-staged-path-only
`.cov` entry for `octal.tl` reports `covered=2 total=4 missing=26,30
note=nil` (correct); a `/zip`-path-only entry (as `cosmic/script_test.tl`
produces, since it execs a built binary) reports `covered=2 total=2
missing= note=open /zip/cosmic/fs/octal.lua: ENOENT` (the collapse).
After applying the one-line fix and rebuilding, re-running the same
merged 418-`.cov`-file report yields `covered=2 total=4 missing=26,30
note=nil` regardless of merge order.

## Non-goals

- **Rewriting `.cosmic-coverage` itself** (running `--baseline` and
  committing the result) is explicitly OUT of this slice. The fix
  changes what `parse` several files' `/zip`-attributed `.cov` entries
  resolve to, and `_tool/coverage/baseline.tl`'s own doc comment warns
  that "several rows were set by hand to the number the strictest
  environment produces... a rewrite from whatever machine is at hand
  would raise them to what THIS machine reaches" — a floor regeneration
  needs its own reviewed change with a diff a human reads (per D27 and
  `baseline.tl`'s `lowered()`), not a side effect bundled into a bug
  fix. Note for that follow-up: the per-file tolerance formula
  (`file_tolerance_pp`, `max(1.0, 200/total)`) is large enough for
  4-line files that `cosmic/fs/octal.tl`'s true 2/4 does **not** trip
  the ratchet against the committed (wrong) 2/2 today — `have=50.0` is
  not `< want(100.0) - slack(50.0)`. So this fix will not turn CI red;
  the stale `2 2` row can be corrected in its own follow-up at leisure.
- **Every other `.cosmic-coverage` row.** This investigation confirms
  the mechanism and one instance (`cosmic/fs/octal.tl`); it does not
  attempt to audit which, if any, other rows are similarly deflated by
  the same first-wins-the-race bug. That audit is a reasonable
  follow-up but is not this slice.
- **Issue #1205 (bench coverage measurement disagreeing between CI and
  local)** is explicitly out of scope, and I believe it is a **separate
  root cause**, not the same bug: #1205 is described as *covered*-line
  variance tied to a timing-bounded smoke pass (a flaky hit/no-hit on
  timing-sensitive branches), whereas this bug is a *total*-line
  (denominator) collapse from a static-analysis failure on a
  non-timing-dependent file, order-dependent on `.cov` merge order, not
  on timing. Nothing in this investigation found a shared mechanism —
  do not fold #1205 into this fix or close it as a duplicate.
- **`cosmic/fs/octal.tl`'s module-top-level lines (26, 30) never
  registering as "hit."** Independent of this bug: even with the fix
  applied and static analysis succeeding, lines 26 (`local M = {...}`)
  and 30 (`return M`) show up in **every** `.cov` file's hit table for
  this module as absent — the module's top-level code appears to run
  (via `require`) before whatever attaches the coverage line hook in
  every process observed. That may be a real, separate coverage-fidelity
  gap (module-load-time lines undercounted repo-wide) worth its own
  investigation, but fixing or even fully diagnosing it is not this
  slice — this slice only restores the TOTAL to what static analysis
  actually says.
- **The `o/<path>.lua` staged-artifact branch of `normalize()`** (lines
  118-133, the non-`/zip/` compiled-artifact mapping) is not touched —
  it already returns a readable staged Lua **text** file as `parse`,
  confirmed to preserve `tl.generate`'s line-number correspondence with
  the original source, and has its own passing test
  (`test_normalize_maps_compiled_artifact_to_source`).

## Acceptance

```facts
$ o/bin/cosmic --make test _tool/coverage/report_test.tl 2>&1 | tail -3
1 checks: 1 passed
wall: 9ms  slowest: _tool/coverage/report_test.tl (9ms)
test: PASS (1 file)
```

The existing suite passes today, before this slice's change; extend
`test_normalize_maps_embedded_directory_modules` (or add a sibling test)
to assert the second return value too, and it must still pass against
the fixed `normalize()`.

- `_tool/coverage/report_test.tl`'s extended/new test asserts
  `report.normalize("@/zip/cosmic/url.lua", "")`'s **second** return
  value equals `"cosmic/url.tl"` (not `"/zip/cosmic/url.lua"`), and
  passes.
- `o/bin/cosmic --make ci` ends `ci: PASS` (fmt, check, example, lint,
  coverage all still hold; the coverage ratchet still passes against
  the unmodified, still-stale `.cosmic-coverage` — see Non-goals for
  why that's expected and safe).
- Re-running the isolated single-`.cov`-file reproduction above (the
  `/zip`-only case) after the fix and a rebuild now reports
  `cosmic/fs/octal.tl covered=2 total=4 missing=26,30 note=nil` instead
  of `covered=2 total=2 note=<read failure>` — i.e. the two isolated
  reproductions (o/-staged-only vs zip-only) now agree with each other
  and with the direct static analysis of the `.tl` source (4 executable
  lines), which is the actual bug: order-dependence is eliminated
  because `parse` no longer depends on which chunk identity created the
  entry first.

## Enablement

none needed — the fix and its test are confined to
`_tool/coverage/report.tl` and `_tool/coverage/report_test.tl`, both
already read/write within this investigation, with no upstream
dependency, pin bump, or decision-record change required. `--make ci`
is sufficient to validate the whole slice end to end.
