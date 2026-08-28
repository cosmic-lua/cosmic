## Goal

G6 — the defining paths, ratcheted (parent `3HyRcd9F`: a
`perf-compare: FAIL` blocks publishing). **The route is picked and it is
route 2, repaired: give every lane that runs the tree's `_perf` under an
OLDER binary a manifest root scoped to `_perf` ALONE — tree instrument,
each side's own `cosmic` — and then narrow the skew guard's include path
the same way, so a `_perf` signature change lands in one PR while the
cosmic-newer-than-the-pin skew class stays caught.**

The instrument is `_perf/**`; `cosmic/**` is the SUBJECT. A compare is
only a compare if the instrument is held fixed and the subject is not.
Today the baseline side runs the previous release's `_perf` (wrong
instrument); the rejected PR #1463 put the tree's `cosmic/**` on both
sides (subject held fixed, ratchet blind). A `_perf`-scoped root is the
one shape that gives the first without the second, and this item is now
committed to it — measured below, both halves.

This item ABSORBS the guard's behaviour (rejection question 2): its
title claims the signature-change problem, so the guard is in scope, and
without it nothing here unblocks `3IUBNQZZ`. It also absorbs the
changed-existing-bench blind spot, orphaned when `3IVJLeCY` was ended
`not-planned` — the same manifest closes it, measured.

## Evidence — measured 2026-08-27, re-measured at pull 2026-08-28 (session 0b13d2b4)

Tree at `8269ff42` (`origin/main` `a80cf0cd` plus one `_make/patch.tl`
commit that touches no `_perf` file: `git show --stat 8269ff42`).
Re-measured at pull off `origin/main` `835c874d` (#1477 and #1478
landed since; neither touches `_perf`). Every structural claim below
reproduced verbatim; the two numeric drifts are marked inline.
Baseline binary throughout is `o/bootstrap/cosmic`, content-wise the
pinned release: its stamp `o/bootstrap/cosmic.pin` is
`145057b9fe90…` = `bin/cosmic.pin`, while its own
`sha256sum` is `90ff7f246b3f…` (the `--assimilate` mutation).
The 30x demonstration ran in a `cp -a` copy of the tree under
`$TMPDIR`; every command below is literally runnable from the repo root.

### 1. A `_perf`-scoped root gives the split, a `$PWD` root does not

```
mkdir -p o/perf/treeroot/o
ln -sfn "$PWD/_perf" o/perf/treeroot/_perf
ln -sfn "$PWD/o/_perf" o/perf/treeroot/o/_perf
printf 'root %s/o/perf/treeroot\nbuild o\n' "$PWD" > o/perf/tree.modules
cat > o/perf/probe.lua <<'EOF'
for _, n in ipairs({"_perf.harness", "_perf.bench.time_bench",
                    "cosmic.json", "cosmic.teal"}) do
  local m = require(n)
  for _, v in pairs(m) do
    if type(v) == "function" then
      print(n .. " " .. debug.getinfo(v, "S").source); break
    end
  end
end
EOF
o/bootstrap/cosmic o/perf/probe.lua                               # today
o/bootstrap/cosmic --modules o/perf/tree.modules o/perf/probe.lua # this item
```

| module | today (bare) | `root $PWD` (PR #1463) | `_perf`-scoped root |
|---|---|---|---|
| `_perf.harness` | `@/zip/_perf/harness.lua` | `@<root>/o/_perf/harness.lua` | `@<root>/o/_perf/harness.lua` |
| `_perf.bench.time_bench` | `@/zip/…` | `@<root>/o/…` | `@<root>/o/…` |
| `cosmic.json` | `@/zip/cosmic/json.lua` | **`@<root>/o/cosmic/json.lua`** | `@/zip/cosmic/json.lua` |
| `cosmic.teal` | `@/zip/cosmic/teal.lua` | **`@<root>/o/cosmic/teal.lua`** | `@/zip/cosmic/teal.lua` |

`cosmic/searcher.tl`'s `tree_searcher` resolves `<root>/<build>/<rel>.lua`
then `<root>/<rel>.tl` and MISSES otherwise, falling through to `/zip` at
seat 3 — so a root whose only entries are `_perf` and `o/_perf` answers
`_perf.*` and nothing else. No searcher or manifest-format change is
needed for this; the scoping is entirely in what the root directory
contains.

### 2. The regression that PR #1463 made vanish now BLOCKS

A deliberate ~30x slowdown in `cosmic/literal.tl`'s `format` (the pin
layout looped 30x), rebuilt, all four runs in one sitting with
`--only literal --samples 1 --min-secs 0.05`:

| scenario | candidate (`--make run`) | baseline TODAY (bare) | baseline `root $PWD` | baseline `_perf`-scoped |
|---|---|---|---|---|
| `literal_format_pin` | 699.34 µs | 21.71 µs | **623.39 µs** | 19.92 µs |
| `literal_format_floor` | 14.37 ms | 551.07 µs | **15.24 ms** | 484.13 µs |

`o/bin/cosmic --make run _perf/run.tl -- --compare BASE.json CAND.json`
verdict lines:

```
today:          5 scenarios: 2 regression, 2 faster, 1 ok …   (blocks)
root $PWD:      5 scenarios: 1 regression, 0 faster, 4 ok …   (see below)
_perf-scoped:   5 scenarios: 2 regression, 0 faster, 3 ok …   (blocks)
```

`literal_format_pin` reads `+3121.4%` today, `+12.2%` under `root
$PWD`, `+3410.2%` under the `_perf`-scoped root. **Numeric drift at
pull, stated plainly:** the first pass measured the `root $PWD`
baseline reading `-0.6% ok` and PUBLISHING; at pull the same shape read
`+12.2%`, marginally over the flat ±10% bar, so it happened to block on
that scenario. What did not drift is the masking itself — the rejected
shape collapses a 34x regression to 1.12x and turns
`literal_format_floor`'s true `+2867.6%` into `-5.7% ok` — and 12.2%
sits inside the range the gate's own A/A triage discounts, so blocking
there is luck, not a gate. The `_perf`-scoped root reports the real
size on both scenarios in both passes. The rejection's blocking
finding 1 is reproduced and repaired.

### 3. The guard, scoped to `_perf`, clears the arity wall and keeps the skew wall

`--include-dir` prepends to the defaults (`cosmic/_teal_engine.tl`'s
`merge_include_dirs`, "Caller dirs come first"), so a directory holding
only a `_perf` symlink puts the tree's `_perf.*` ahead of
`/zip/.tl/_perf/**` while `cosmic.*` still comes from `/zip/.tl` — the
pin's. With `_perf/compare.tl`'s `format` widened to
`(deltas, _base?, _cur?)` and all five call sites passing three
arguments (exactly `3IUBNQZZ`'s shape):

```
D=$(mktemp -d); ln -s "$PWD/_perf" "$D/_perf"
SRC=$(find _perf -name '*.tl' ! -name '*_test.tl' | sort)
COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types $SRC                      # exit 1
COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types --include-dir "$D" $SRC   # exit 0
```

bare: 5 x `wrong number of arguments (given 3, expects 1)` at
`_perf/gate.tl:143,199,250,290` and `_perf/run.tl:358`.
scoped: exit 0, `Type check passed` x30, zero errors.

And the class the guard exists for still fails under the scope. With a
`probe_new_api` added to the TREE's `cosmic/literal.tl` and used from a
`_perf` file:

```
bare      → _perf/probe_skew.tl:4:51: error: invalid key 'probe_new_api' … (exit 1)
scoped    → _perf/probe_skew.tl:4:51: error: invalid key 'probe_new_api' … (exit 1)
--include-dir .  → exit 0   ← the trap, still a trap
```

### 4. The changed-existing-bench blind spot closes

`_perf/run.tl:194` discovers benches by `fs.find("_perf/bench", …)` of
the TREE and loads each by `require`, so names come from the tree and
bytes from whatever answers. Bare, a bench the pin already carries runs
the PIN's body. Under the scoped root it runs the tree's:

```
rm -rf o/perf/blindspot; mkdir -p o/perf/blindspot/o
cp -r _perf o/perf/blindspot/_perf && cp -r o/_perf o/perf/blindspot/o/_perf
sed -i 's/name = "time_format_date"/name = "time_format_date_TREEMARK"/' \
  o/perf/blindspot/o/_perf/bench/time_bench.lua
printf 'root %s/o/perf/blindspot\nbuild o\n' "$PWD" > o/perf/blindspot.modules
o/bootstrap/cosmic _perf/run.tl --only time --samples 1 --min-secs 0.05
o/bootstrap/cosmic --modules o/perf/blindspot.modules o/_perf/run.lua \
  --only time --samples 1 --min-secs 0.05
```

bare prints `time_format_date`; scoped prints `time_format_date_TREEMARK`.

### 5. Two more sites the rejected spec missed

- **`_perf/gate.tl:357` hardcodes the bare baseline argv**
  (`{baseline_bin, "_perf/run.tl", "--out", out}`) with a comment
  naming it "the exact invocation shape release.yml measures the
  baseline with". `release.yml:184` passes `--baseline-bin`, so a
  flagged regression's RETRY re-measures the baseline. Changing only
  release.yml would make pass 1 and the retry disagree about which
  `_perf` they measure — the retry is what decides the gate.
  `grep -c '"_perf/run.tl"' _perf/gate.tl` → 1 today.
- **The `peers` job carries no skew and is not a reason for anything.**
  `release.yml:255-291` downloads artifact `cosmic-lua` from
  `needs: build` — the CANDIDATE binary, built from this tree — so its
  embed equals the tree by construction. PR #1463's claim that the
  guard "keeps its job" because of the peers lane is false.

### 6. The whole baseline suite runs clean under the scoped root

```
o/bootstrap/cosmic --modules o/perf/tree.modules o/_perf/run.lua \
  --samples 1 --min-secs 0.05 --out o/perf/full.json
```
48 scenarios, 0 errors, 10.3 s wall; `meta.bin_sha` = `sha256sum
o/bootstrap/cosmic`, not `o/bin/cosmic`.

## Change

Seven files, plus the coverage floor.

**1. New `_perf/baserun.tl`** — the ONE definition of "measure a
baseline binary against the tree's `_perf`", so the workflow and the
gate's retry cannot drift apart. Two exported functions plus a script
mode:

```teal
--- @return string|nil Absolute path of the manifest written
local function ensure_root(root: string, build: string): string | nil, string
local function argv(bin: string, modules: string, extra: {string}): {string}
```

`ensure_root` makes `<root>/<build>/perf/treeroot/o`, symlinks
`<root>/_perf` → `treeroot/_perf` and `<root>/<build>/_perf` →
`treeroot/o/_perf` (idempotent: skip an existing link), writes
`<root>/<build>/perf/tree.modules` holding exactly
`root <abs treeroot>` and `build o`, and returns that path. It creates
NO other entry under `treeroot` — that emptiness IS the fix.
`argv` returns `{bin, "--modules", modules, "o/_perf/run.lua", extra…}`.
Script mode (`proc.is_main()`): parse `--bin PATH`, pass every other
argument through, `ensure_root(fs.cwd(), "o")`, `child.run` with
`stdout`/`stderr` inherited, exit with the child's code (three
`os.exit` sites, each carrying `-- exits: process boundary`).
Measured: this exact prototype type-checks under the PIN
(`o/bootstrap/cosmic --check types --include-dir "$D" _perf/baserun.tl`
→ passed), and `bin/cosmic --make run _perf/baserun.tl --bin
o/bootstrap/cosmic --only time --samples 1 --min-secs 0.05 --out
o/perf/prev-probe.json` ran under the fence and wrote
`bin_sha 90ff7f246b3f…` (the OLD binary). The entry must be
`o/_perf/run.lua`, not `_perf/run.tl`: a `.tl` entry is type-checked
through the binary's include path, which finds `/zip/.tl/_perf/*.tl`
before any `require` runs.

**2. New `_perf/baserun_test.tl`** — cases: `ensure_root` in
`TEST_TMPDIR` writes a manifest whose `root` line points at
`treeroot`; **the constructed root's entries are exactly `_perf` and
`o`, and `o`'s entries exactly `_perf`** (the structural wall against
the `root $PWD` over-capture); a second `ensure_root` call is
idempotent; `argv` puts `--modules` before the entry and appends extras
in order. Each `test_*` called on the line after its `end`.

**3. `_perf/gate.tl`** — in `measure_baseline` (currently 351-361),
replace the hardcoded `{baseline_bin, "_perf/run.tl", "--out", out}`
with `baserun.argv(baseline_bin, baserun.ensure_root(cwd, "o"), …)`,
requiring `_perf.baserun` beside the existing `local child =
require("cosmic.child")`. Rewrite the comment above it to say the shape
is `baserun`'s, shared with release.yml, and why (the retry must
resolve `_perf` exactly as pass 1 did). A failed `ensure_root` returns
1 with its message on stderr, like the existing child failure. Headroom:
`wc -l _perf/gate.tl` = 406, 94 lines under the 500 cap.

**4. `.github/workflows/release.yml`** — in the "compare against the
previous release" step, replace line 181

```
o/perf/prev/cosmic-lua _perf/run.tl --out o/perf/prev/perf.json
```

with

```
o/bin/cosmic --make run _perf/baserun.tl --bin o/perf/prev/cosmic-lua \
  --out o/perf/prev/perf.json
```

Nothing else in the step moves: `baseline.tl`, the SKIP branch, the
`chmod +x`, `--baseline-bin`, the `| tee`, `pipefail` and `exit "$rc"`
all stand. And rewrite the parenthetical at lines 162-163 — "(the
previous binary measures its own embedded scenario set, exactly as its
stored numbers did)" — which this change falsifies. The phrase
`embedded scenario set` must not survive it: that is precisely what
stops being true (see *What this changes about the gate's meaning*).

**5. `_perf/skew_test.tl`** — build a `_perf`-only include directory in
`TEST_TMPDIR` (`fs.symlink(fs.join(cwd, "_perf"), fs.join(tmp,
"_perf"))`), assert its entries are exactly `{"_perf"}` before using
it, and pass `--include-dir <that dir>` to the child `--check types`.
Then rewrite the header and the assert message:

- delete "`_perf.*` resolves from the tree at cwd" — false in every
  context measured here and in the sidecar's earlier passes;
- say what the guard now checks: every non-test `_perf/**` source
  against the PIN's `cosmic.*` declarations and against the TREE's own
  `_perf.*` declarations, because after change 4 the baseline lane runs
  the tree's `_perf` on the previous release's `cosmic`;
- say why the include dir is scoped: `--include-dir .` at the repo root
  resolves `cosmic.*` from the tree and silently defeats the guard
  (measured: exit 0 with an invented API in use);
- the failure message stops prescribing the tolerant-map-view remedy as
  the only reading. Both readings: a `cosmic` API newer than the pin
  takes the map view or waits for the pin; anything else is a genuine
  type error in a `_perf` file.

Headroom: `wc -l _perf/skew_test.tl` = 70.

**6. `_build/workflows_test.tl`** — extend
`test_the_release_perf_compare_propagates_its_verdict` (or add one
beside it) asserting the compare step's baseline measurement goes
through `_perf/baserun.tl` and that the step body does NOT contain
`cosmic-lua _perf/run.tl`. Headroom: `wc -l _build/workflows_test.tl` =
329.

**7. `skills/optimize/SKILL.md`** — its warning that `$BIN
o/_perf/run.lua …` "reads like the fix and is not" stays true for a
BARE run; add the one exception in the same bullet: with `--modules`
naming a `_perf`-scoped root it resolves the tree's `_perf` against the
binary's own `cosmic`, which is what the release baseline uses and what
`_perf/baserun.tl` builds.

**Coverage.** New files move the ratchet: run exactly the regen the
gate's failure prints (`bin/cosmic --make coverage --baseline`) and
commit `.cosmic-coverage`. Never weaken the gate any other way.

## Non-goals

- **No `root $PWD` and no repo-root manifest anywhere.** That is the
  rejected shape; the treeroot's emptiness is the fix and
  `_perf/baserun_test.tl` is what holds it.
- **No `--include-dir .`** in the guard or anywhere else — measured to
  defeat it silently.
- No change to `cosmic/searcher.tl`, the `--modules` manifest format,
  `_cli/**`, `_make/**`, or `bin/cosmic.pin`.
- No change to `_perf/compare.tl` — its `format` signature is
  `3IUBNQZZ`'s to widen. This item only removes the wall.
- No scenario, `check()`, threshold, bar or noise-floor change. In
  particular `codec_base64_roundtrip_64k` keeps its floor, and
  `_perf/compare.tl:115-121`'s missing-scenario rule is not touched.
- No change to the `peers` job: it runs the CANDIDATE artifact, so it
  carries no skew (measured, Evidence 5).
- No change to `3p/tl/tl_patch/**` or `_make/patch.tl` — live siblings
  `3IVSDpFq` (#1477), `3IVZsiwL` (#1478), `3IVenbbU` (#1479).
- No rewrite of `docs/design/make/resolution.md`; its table describes
  BARE runs and stays true.
- No decision record: a lane is being made to measure what it always
  claimed to measure.
- No attempt to guard the `cosmic`-on-old-`cosmo` surface (below) —
  naming it is this item's job, guarding it is not.

## What this changes about the gate's meaning

Stated so a reviewer judges it rather than discovers it.

1. **The baseline number changes meaning, deliberately.** It becomes
   "the previous release's `cosmic` measured by the tree's instrument"
   instead of "the previous release measured by its own instrument".
   That is the experiment the compare has always claimed to run: one
   instrument, two subjects.
2. **A scenario-set change stops being a gate event.** Both sides now
   enumerate the tree's benches, so a rename or removal no longer shows
   up as "present in baseline, missing in current"
   (`_perf/compare.tl:115-121`) and the `perf_gate: false` re-baseline
   door is no longer needed for one. The deletion of a scenario is
   visible in the PR diff and to `--make ci`; the release gate's job is
   regressions. The comment at `release.yml:162-163` must say this
   instead of what it says now.
3. **The tree's `_perf` now runs entirely on the previous release's
   `cosmic` and `cosmo`** — previously only the path-given entry was
   tree code. A `_perf/**` use of a `cosmic` API newer than the pin
   therefore breaks the baseline side, which is exactly the class
   `_perf/skew_test.tl` catches, so the guard becomes MORE load-bearing
   after this change, not less. The residue it cannot see is a `cosmic`
   module that type-checks against the pin and fails at RUNTIME on the
   old `cosmo`; measured clean today (48 scenarios, 0 errors) but that
   is one observation, not a guard.

## Acceptance

`o/bootstrap/cosmic` stands in for the previous release: its stamp
`o/bootstrap/cosmic.pin` matches `bin/cosmic.pin`
(`145057b9fe90…`) while its own sha is `90ff7f246b3f…`.
Quote both shas in the PR. Nothing here writes into the committed tree.

- `bin/cosmic --make ci` ends `ci: PASS`.

- **New unit and workflow tests pass.**
  `bin/cosmic --make test _perf/baserun_test.tl` ends `test: PASS`;
  `bin/cosmic --make test _build/workflows_test.tl` ends `test: PASS`.

- **The root is scoped, not the repo.** After
  `bin/cosmic --make build && bin/cosmic --make run _perf/baserun.tl
  --bin o/bootstrap/cosmic --only time --samples 1 --min-secs 0.05
  --out o/perf/prev-probe.json`:
  - `ls o/perf/treeroot` → exactly `_perf` and `o`;
    `ls o/perf/treeroot/o` → exactly `_perf`.
  - `grep -c "^root .*/o/perf/treeroot$" o/perf/tree.modules` → 1, and
    `grep -c "^root $PWD$" o/perf/tree.modules` → 0.

- **It measures the OLD binary.**
  `grep -o '"bin_sha":"[a-f0-9]*"' o/perf/prev-probe.json` equals
  `sha256sum o/bootstrap/cosmic`, and differs from
  `sha256sum o/bin/cosmic`. Quote all three.

- **It measures the TREE's `_perf` on the BINARY's `cosmic`** — the
  before/after of this whole item. With the probe of Evidence 1:
  `o/bootstrap/cosmic o/perf/probe.lua` prints `_perf.harness
  @/zip/_perf/harness.lua`; `o/bootstrap/cosmic --modules
  o/perf/tree.modules o/perf/probe.lua` prints `_perf.harness` under
  `o/perf/treeroot/o/`, AND `cosmic.json @/zip/cosmic/json.lua` and
  `cosmic.teal @/zip/cosmic/teal.lua` in BOTH. Quote all six lines: a
  `cosmic.*` line naming a repo path is the rejected over-capture and
  fails this item.

- **A `cosmic/**` regression still blocks.** Run Evidence 2 verbatim:
  patch `cosmic/literal.tl`'s `"pin"` branch to loop `lformat.format`
  30 times, `bin/cosmic --make build`, then measure candidate
  (`bin/cosmic --make run _perf/run.tl -- --only literal --samples 1
  --min-secs 0.05 --out o/perf/cand.json`) and baseline
  (`bin/cosmic --make run _perf/baserun.tl --bin o/bootstrap/cosmic
  --only literal --samples 1 --min-secs 0.05 --out o/perf/base.json`),
  and compare (`bin/cosmic --make run _perf/run.tl -- --compare
  o/perf/base.json o/perf/cand.json`). The report must end
  `2 regression` with `literal_format_pin` over `+2000%`. Revert the
  patch (`git checkout cosmic/literal.tl`) and confirm `git status
  --short` is clean before opening the PR.

- **The changed-existing-bench blind spot is closed.** Run Evidence 4
  verbatim: bare prints `time_format_date`, the scoped-root run prints
  `time_format_date_TREEMARK`.

- **The guard clears a sibling signature change and still catches
  cosmic skew.** With `_perf/compare.tl`'s `format` widened to
  `(deltas: {pt.Delta}, _base?: pt.Results, _cur?: pt.Results)` and the
  five call sites at `_perf/gate.tl:143,199,250,290` and
  `_perf/run.tl:358` passing `(deltas, nil, nil)`:
  `bin/cosmic --make test _perf/skew_test.tl` ends `test: PASS`
  (today the same edit gives `test: FAIL` with five `wrong number of
  arguments`). Then, keeping that edit, add a `_perf` file calling an
  invented `cosmic.literal` function: the same command ends
  `test: FAIL` naming `invalid key`. Revert both probes; `git status
  --short` clean.

- **The guard's prose and scope are what the Change says.**
  `grep -c 'resolves from the tree at cwd' _perf/skew_test.tl` → 0
  (1 today); `grep -c -- '--include-dir' _perf/skew_test.tl` → 1
  (0 today); `grep -c -- '--include-dir \.' _perf/skew_test.tl` → 0.

- **No bare baseline invocation survives.**
  `grep -c '"_perf/run.tl"' _perf/gate.tl` → 0 (1 today);
  `grep -c 'cosmic-lua _perf/run.tl' .github/workflows/release.yml` → 0
  (1 today); `grep -c 'embedded scenario set' .github/workflows/release.yml`
  → 0 (1 today).

- **The `_perf` source count moved by exactly one.**
  `find _perf -name '*.tl' ! -name '*_test.tl' | wc -l` → 31 (30 today).

- **The diff is exactly these files.**
  `git diff origin/main...HEAD --name-only` →
  `.cosmic-coverage`, `.github/workflows/release.yml`,
  `_build/workflows_test.tl`, `_perf/baserun.tl`,
  `_perf/baserun_test.tl`, `_perf/gate.tl`, `_perf/skew_test.tl`,
  `skills/optimize/SKILL.md` — and nothing else. No `o/perf/*.json` is
  committed.

## Enablement

None needed as a blocker item, and the reasoning is mechanical rather
than asserted. The three wrong turns this item's own history proves a
session can take each have a countermeasure INSIDE the Acceptance,
where a reviewer must see it:

- **the over-capture** (`root $PWD`) — `_perf/baserun_test.tl`'s
  structural assertion on the treeroot's entries, plus the six-line
  resolution probe that fails the item if any `cosmic.*` line names a
  repo path;
- **defeating the guard** (`--include-dir .`) — the guard asserts its
  own scope dir holds exactly `_perf`, and the acceptance greps for the
  literal `--include-dir .`;
- **forgetting the gate's retry path** — `grep -c '"_perf/run.tl"'
  _perf/gate.tl` → 0.

Nothing must land first: `3IUBNQZZ` is DOWNSTREAM of this item, not
upstream, and the pin does not move (measured: the new module
type-checks under `o/bootstrap/cosmic`, so the cold-build rule is not
engaged).

## History — why this item was rejected once and bounced once

- `a4839510` stopped at the evidence with three routes open.
- `cc377d8d` picked route 3 (guard only); `2b1acdcc` silently replaced
  it with a route-2 `## Change` and deleted the pick, leaving three
  open routes standing above a Change that had taken one.
- PR #1463 built that Change and was REJECTED at head `15cab039` on two
  blocking findings: `root $PWD` captured `cosmic/**` and made a 30x
  `cosmic/literal` regression read `-15%` and publish; and the route was
  never named, while its claimed payoff (unblocking `3IUBNQZZ` in one
  PR) measured false because the guard's behaviour was a Non-goal.
- This pass settles both: the route is named in the Goal, the
  over-capture is repaired by scoping the root to `_perf` (Evidence 1
  and 2), and the guard's behaviour is IN scope (Evidence 3), which is
  what actually unblocks `3IUBNQZZ`. The rejection's non-blocking
  finding 3 (`release.yml:162-163`) is carried in Change 4. The
  ownerless changed-bench blind spot from `3IVJLeCY` (ended
  `not-planned`) is absorbed here (Evidence 4) and needs no re-filing.
- Nothing worth keeping from PR #1463's diff is lost: its rewritten
  `skew_test.tl` docstring and assert message were judged worth keeping
  and Change 5 rewrites the same two places, further.
