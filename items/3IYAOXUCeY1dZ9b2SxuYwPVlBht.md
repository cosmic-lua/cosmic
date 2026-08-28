## Goal

G6 — the defining paths, ratcheted. The release compare step IS that
ratchet, and `_perf/run.tl` and `_perf/bench/literal_bench.tl` are two of
the files it loads under a foreign binary. Each carries a workaround for
that lane whose stated reason is false and whose mechanism is now inert:
delete both, so the ratchet's own instrument carries only what it needs.

## Change

Delete both tolerant map views, call the typed APIs, and rewrite the
committed cast floor. Four files, one of them a generated baseline.

**1. `_perf/run.tl`** — replace lines 148-166 (the seven-line comment, the
two `-- cast:` justifications, the `version_fn` lookup and its `type()`
guard) with the typed read:

```teal
  -- Absent rather than guessed, like `bin_sha` above: outside a packed
  -- binary there are no stamps, and a results file that cannot name the
  -- versions it measured carries neither field.
  local v = cosmic.version_info()
  if v then
    meta.cosmic_version = v.cosmic
    meta.cosmos_version = v.cosmos
  end
```

`cosmic.version_info` is declared `function(): VersionInfo | nil` with
`cosmic: string` and `cosmos: string` (`cosmic/init.tl:11-14, 55, 86`), so
the guard on the local is the whole narrowing and no cast survives.
`local cosmic = require("cosmic")` at `_perf/run.tl:17` stays — this is now
its only use. 405 → 394 lines.

**2. `_perf/bench/literal_bench.tl`** — delete lines 67-89 whole: the
ten-line comment, the three `-- cast:` justifications, `lit`, `format_any`,
`format_one`, and `supports_compact`. Then make the compact scenario
unconditional — replace lines 183-194 (keeping the `-- Third, not
appended:` comment at 180-182 exactly as it is) with:

```teal
  table.insert(list, 3, {
      name = "literal_format_floor_compact",
      fn = function(_: any): any
        return (literal.format(FLOOR, {layout = "compact"}))
      end,
      check = function(_: any, res: any): boolean, string
        return verify("literal_format_floor_compact", res, FLOOR_ROWS, FLOOR_KEY,
          "covered", FLOOR_COVERED)
      end,
    })
```

206 → 180 lines. `literal` is already required at line 18 and already used
by the other four scenarios.

**3. `_perf/skew_test.tl`** — three mentions of `literal_bench` become
dangling once the pattern is gone: it is the file skew_test tells a future
session to copy. State the pattern in place instead. Exactly three edits,
nothing else in the file:

- lines 9-14 become

```teal
--- therefore crashes the release lane days after the use merges, with
--- no PR left to attribute it to. The baseline side runs the tree's
--- `_perf` entirely, not only its path-given entry, so every module in
--- it is exposed, not just the harness.
```

- lines 32-36 become

```teal
--- When this fails, read it two ways. A `cosmic` API newer than the
--- pin: wait for the pin to catch up, or reach the API through a
--- tolerant map view plus a capability probe -- look the name up on
--- `<module> as {string: any}`, confirm at run time that this binary
--- really has it, and skip the work when it does not. Anything else:
--- a genuine type error in a `_perf` file, to fix as one.
```

- lines 101-103, inside the assert message, become

```teal
    "a cosmic API newer than the pin, wait for the pin, or look the " ..
    "name up on a {string: any} view of the module and probe at run " ..
    "time that this binary has it; otherwise it is an ordinary type " ..
    "error:\n" .. r.stderr)
```

The file stays 105 lines. Nothing outside skew_test reads that message:
`git grep -n 'tolerant map view' -- .` returns only `_perf/skew_test.tl:33`
and `:101`.

**4. Rewrite the cast floor.** Both files drop to zero casts, so the
ratchet fails with "file(s) under their cast baseline" until the floor is
rewritten. Run exactly the command its failure prints —
`bin/cosmic --make run _build/casts.tl --baseline` — and commit
`_build/casts_baseline.tl`. Today it carries
`["_perf/bench/literal_bench.tl"] = 3` and `["_perf/run.tl"] = 2` at lines
12 and 15; both rows disappear. No other row may move.

**5. If, and only if, the coverage ratchet complains**, run exactly
`bin/cosmic --make coverage --baseline` and commit `.cosmic-coverage`. The
two rows at risk are `["_perf/bench/literal_bench.tl"] = {82, 87}` and
`["_perf/run.tl"] = {97, 191}` (`.cosmic-coverage:102, 120`); both lose
executable lines, and run.tl's percentage sits within a point of its own
tolerance, so a regen may or may not be needed. Never lower a row by hand,
and never lower one the gate did not name.

## Non-goals

- **Do not rewrite either comment and keep its map view.** That was the
  shape this item was filed as; the Evidence below shows the tolerance is
  inert under the oldest binary the guard promises, so the honest change is
  the deletion. A comment explaining a mechanism that does nothing is worse
  than the wrong comment it replaces.
- **Do not touch `_perf/skew_test.tl`'s mechanism.** Its argv, its
  `perf_only_include_dir`, its bootstrap assertion and its file sweep are
  the gate that makes these typed calls safe. Only the three literal_bench
  mentions and the sentence carrying them change; do not weaken, skip, or
  delete the test, and do not audit the rest of its prose here.
- **No change to the lane or its callers**: `_perf/baserun.tl`,
  `_perf/baseline.tl`, `_perf/gate.tl`, `_perf/compare.tl`,
  `.github/workflows/release.yml` are all out of scope. `_perf/gate.tl` and
  `_perf/compare.tl` in particular have open PRs against them (#1485,
  #1486); this slice must not touch them.
- **No results-file schema change.** `pt.Meta.cosmic_version` and
  `pt.Meta.cosmos_version` stay optional and stay absent when
  `version_info()` returns nil. No placeholder word is ever written into
  them, which is the doctrine the paragraph at `_perf/run.tl:133-140`
  states for `bin_sha`.
- **No scenario, threshold, check, or noise bar moves.**
  `literal_format_floor_compact` keeps its name, its position (index 3),
  its `verify` arguments, and its input. This is not a perf change and
  makes no timing claim.
- **Do not touch `docs/design/make/resolution.md`.** It cites
  `_perf/run.tl:163` as an inline citation, which the citations lint
  resolves by position only; run.tl stays 394 lines, well past 163, so the
  lint still passes. Its prose names `pcall(require, name)`, which is at
  `_perf/run.tl:175` today and would move to `:164` — already stale before
  this slice and not this slice's business.
- **No new `as` cast anywhere in the diff**, and no `-- cast:` comment left
  behind without its cast.

## Acceptance

Run from the repo root. Nothing under `o/` is committed.

1. `bin/cosmic --make ci` ends `ci: PASS (5 stages)`.

2. `bin/cosmic --make test _perf` ends `test: PASS (N files)`, with
   `_perf/skew_test.tl` among the files that passed.

3. The casts are gone and the floor agrees:

```
grep -c -- '-- cast:' _perf/run.tl _perf/bench/literal_bench.tl
  → _perf/run.tl:0 and _perf/bench/literal_bench.tl:0   (2 and 3 on origin/main)
grep -c -E '_perf/(run|bench/literal_bench)\.tl' _build/casts_baseline.tl
  → 0                                                    (2 on origin/main)
```

4. No dangling pointer is left:

```
grep -c literal_bench _perf/skew_test.tl   → 0   (3 on origin/main)
```

5. **The lane still works under the oldest binary the guard promises, and
   both effects the tolerance was protecting are present.** This is the
   decisive check: it runs the PINNED release binary against the tree's
   `_perf`, which is exactly the shape `release.yml:184` uses.

```
o/bin/cosmic --make run _perf/baserun.tl --bin o/bootstrap/cosmic \
  --only literal --out o/perf/skewprobe.json _perf.bench.literal_bench
```

   ends `wrote o/perf/skewprobe.json`, exits 0, and prints five scenario
   rows, one of them named `literal_format_floor_compact`. Then:

```
grep -c literal_format_floor_compact o/perf/skewprobe.json   → 1
grep -c '"cosmic_version"' o/perf/skewprobe.json             → 1
grep -c '"cosmos_version"' o/perf/skewprobe.json             → 1
```

   The row timings are not a claim and are not compared to anything.

6. The pinned-checker sweep, by hand, over just the two edited sources —
   the same check `_perf/skew_test.tl` runs over all 31:

```
mkdir -p o/perf/skew-inc && ln -sfn "$PWD/_perf" o/perf/skew-inc/_perf &&
  COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types \
    --include-dir o/perf/skew-inc _perf/run.tl _perf/bench/literal_bench.tl
```

   prints `Type check passed:` for both and exits 0.

7. Bounds hold:

```
wc -l _perf/run.tl _perf/bench/literal_bench.tl _perf/skew_test.tl
  → 394, 180, 105   (405, 206, 105 on origin/main; the cap is 500)
awk 'length>90' _perf/run.tl _perf/bench/literal_bench.tl _perf/skew_test.tl | wc -l
  → 1               (1 on origin/main: the pre-existing 97-column line at
                     _perf/run.tl:349, which this slice does not touch)
```

8. The diff touches exactly four paths, five if the coverage regen fired:

```
git diff origin/main --name-only
  → _perf/bench/literal_bench.tl
    _perf/run.tl
    _perf/skew_test.tl
    _build/casts_baseline.tl
    [.cosmic-coverage, only if step 5 of Change fired]
```

9. Composition with the two open `_perf` PRs, if either is still open at
   pull time:

```
git fetch origin refs/pull/1485/head refs/pull/1486/head
git merge-tree --write-tree --messages HEAD <each fetched sha>
```

   must exit 0 for both.

## Enablement

none needed. The one countermeasure this change depends on already exists
and already runs in `--make ci`: `_perf/skew_test.tl` type-checks every
non-test `_perf/**` source against the pinned bootstrap, which is what
makes a typed `cosmic.*` call in `_perf` safe under the release lane's
foreign binary. The typed forms of both call sites were run through that
exact sweep during this refinement and passed. The one debt the deletion
creates — skew_test's failure message pointing at an exemplar that will no
longer exist — is step 3 of `Change`, not a separate item: it is four lines
in the file the deletion invalidates.

## Evidence — re-measured 2026-08-28 against `origin/main` `40776231`

`origin/main` had not moved since the item was filed: `git fetch origin
main && git rev-parse --short origin/main` → `40776231`. Every `file:line`
the item cited still points where it said, and one span was widened for
accuracy: the false claim in `_perf/run.tl` runs 148-154 with its `-- cast:`
at 155 (the item wrote 149-152), and in `_perf/bench/literal_bench.tl` it
runs 67-76 with `-- cast:` at 77 (the item wrote 67-72). `release.yml:184`,
`_perf/baserun.tl:40` (`ENTRY = "o/_perf/run.lua"`) and `_perf/baserun.tl:126`
(`{bin, "--modules", modules, ENTRY}`) all reproduce, as does
`ls o/_perf/bench/*.lua | wc -l` → 18.

**The item's premise holds: the lane no longer type-checks anything.**
`_perf/baserun.tl:35-39` says so in its own words — the entry is the built
`.lua` precisely because a `.tl` entry would be type-checked — and the
scoped root serves `<root>/o/<rel>.lua` before `<root>/<rel>.tl`
(`_perf/baserun.tl:13-22`). So "runs this script bare" and "load-time type
error" are both false today.

**The item's proposed replacement reason is ALSO wrong, which is why this
slice is a deletion.** The item asserts the map views are now held in place
by `_perf/skew_test.tl`. They are not: both typed forms pass that exact
sweep under the pin. Reproduced by copying `_perf` to a scratch directory,
applying the typed forms, and running skew_test's own command over all 31
non-test sources:

```
git archive origin/main _perf | tar -x -C $S/src
mkdir -p $S/inc && ln -sfn $S/src/_perf $S/inc/_perf
cd $S/src && o/bootstrap/cosmic --check types --include-dir $S/inc \
  $(find _perf -name '*.tl' ! -name '*_test.tl' | sort)
  → 31 files, all "Type check passed", rc 0 — before and after the typed edits
```

Directly, on the pin: `o/bootstrap/cosmic --check types` over
`local v = cosmic.version_info()` resolves `version_info` and returns
`VersionInfo | nil` (it errors only on the unguarded index, which is the
narrowing this slice writes), and over
`literal.format({alpha = 1}, {layout = "compact"})` it prints
`Type check passed`. The pin is `2026-08-27-555873e`
(`bin/cosmic.pin`); `o/bootstrap/cosmic --version` →
`cosmic-lua unknown (cosmos 2026.08.27-13977f2ef, Lua 5.4)`.

**Nothing fails at run time either.** On the same pinned binary:

```
o/bootstrap/cosmic -e 'local c=require("cosmic") local v=c.version_info()
  print(v and v.cosmic, v and v.cosmos)'
  → unknown	2026.08.27-13977f2ef
o/bootstrap/cosmic -e 'local l=require("cosmic.literal")
  print(l.format({alpha=1},{layout="compact"}) ~= l.format({alpha=1}))'
  → true
```

The second line is `supports_compact()`'s own probe: it already answers
true on the pin, so the guard it feeds is never false and the scenario
always registers.

**End to end, through the real lane mechanism, with the typed code.** The
typed sources were compiled and dropped into a scoped root built exactly
like `_perf/baserun.tl`'s, and the pinned binary ran them:

```
o/bootstrap/cosmic --modules $S/tree.modules o/_perf/run.lua \
  --only literal --out $S/typed-prev.json _perf.bench.literal_bench
  → five rows, all checks passed, including
    literal_format_floor_compact    2244 x    76.79 µs/op
  → meta carries "cosmic_version":"unknown","cosmos_version":"2026.08.27-13977f2ef"
  → rc 0
```

The unmodified tree, run the same way through
`o/bin/cosmic o/_perf/baserun.lua --bin o/bootstrap/cosmic`, produces the
same five rows and the same two stamps — so the map views are already
doing nothing on the oldest binary the guard covers.

**The lower bound is structural, not a coincidence of today's pin.**
`_perf/baseline.tl:122-130` picks the baseline as the newest release by
`created_at`, prereleases included; the pin points at a published release
and only ever moves forward. So the compare step's binary is always at
least as new as the pin, and `_perf/skew_test.tl` proves the whole of
`_perf` type-checks against the pin. The latest release today is
`2026-08-27-46abc86`, published four hours after the pin's
`2026-08-27-555873e`.

**The tolerance was never general anyway.** Every other `cosmic.*` call in
`_perf/**` is typed and unguarded; these two were the only exceptions, and
what actually protects all of them is skew_test. Keeping two guarded call
sites among thirty-one unguarded files buys nothing and asserts something
false about the other twenty-nine.

**Collision check — both open `_perf` PRs merge clean.** A candidate commit
carrying all three edits was built on `origin/main` with `git commit-tree`
(no branch, no checkout) and merged against each PR head:

```
git fetch origin refs/pull/1485/head:refs/tmp/pr1485 \
                 refs/pull/1486/head:refs/tmp/pr1486
git merge-tree --write-tree --messages <candidate> refs/tmp/pr1485
  → 54f3cd991af518dc9d130e757b4184605954a9dc
    Auto-merging _perf/run.tl        (rc 0, no conflict)
git merge-tree --write-tree --messages <candidate> refs/tmp/pr1486
  → 910e71854d8c19e1083f4b0c0b84cc1998a006aa   (rc 0, no overlap at all)
```

#1485 (`claude/3IUBNQZZ-compare-rows`, `37ea41cb`) touches
`_perf/run.tl:358`, 192 lines below this slice's 148-166; #1486
(`claude/3IVLAF3Z-stampless-identity-v2`, `2a29c4d3`) touches
`_perf/compare.tl`, `_perf/gate.tl` and two gate tests, none of them this
slice's files. No `block` edge is warranted.

**What the whole change measures.** `git diff --stat origin/main <candidate>`
→ `_perf/bench/literal_bench.tl 46 -, _perf/run.tl 25 -, _perf/skew_test.tl
26 -`, 30 insertions and 67 deletions across three files, before the
generated `_build/casts_baseline.tl` row removals.
