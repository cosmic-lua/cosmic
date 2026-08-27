## Evidence

`_perf/skew_test.tl` type-checks every non-test `_perf/**` file under
the pinned bootstrap binary. Its docstring claims "`_perf.*` resolves
from the tree at cwd." It does not: the cosmic binary embeds its own
`_perf` sources at `.tl/_perf/*.tl`, and that include path SHADOWS the
tree. Measured in an empty directory holding only a `probe.tl` that
requires `_perf.compare`, with no `_perf` tree present at all:

```
$ o/bootstrap/cosmic --check types probe.tl
Type check passed: probe.tl
```

So the guard checks the tree's `_perf/gate.tl` and `_perf/run.tl`
against the PINNED RELEASE's `_perf/compare.tl`, not the tree's.

**The consequence is general: any change to a `_perf` module's
exported signature that a sibling `_perf` module calls is unlandable
in one PR.** Found by 3IUBNQZZ, which widens `compare.format` with two
optional parameters and is called from both siblings:

```
_perf/gate.tl:128:23: error: wrong number of arguments (given 3, expects 1)
_perf/run.tl:358:23: error: wrong number of arguments (given 3, expects 1)
```

Causation proven both ways: `git stash` then
`bin/cosmic --make test _perf/skew_test.tl` ends `test: PASS`;
unstashed it fails. `_perf/compare.tl` has not been touched since the
skew guard landed (`ccd246ab`, #1427; last compare.tl change
`ef963bab`, #1419), so 3IUBNQZZ is the FIRST change to a `_perf`
module's exported signature after the guard and no precedent exists.

**The guard's error message is misleading in this case.** It says "a
`_perf` file reaches an API the pinned bootstrap does not declare" and
directs the reader to the map-view / capability-probe pattern — correct
for a *cosmic* API newer than the pin, actively wrong for a sibling
`_perf` module, where the honest reading is "you changed a `_perf`
signature and the guard is comparing you against the pinned release's
copy of it." Applying the prescribed pattern to one's own sibling
module would add unjustifiable casts.

## The decision this needs

Either the guard should place the tree AHEAD of the binary's embedded
`.tl/_perf` — which would make it match its own docstring and unblock
ordinary `_perf` refactoring — or `_perf` signature changes are
genuinely meant to stage behind a release and pin bump, in the same
shape as CLAUDE.md's cold-build rule, in which case the docstring and
the error message must say so and the cost should be recorded. Until
one is chosen, 3IUBNQZZ (and every future `_perf` signature change) is
blocked on an undocumented two-PR-plus-a-release dance.

## Correction — 2026-08-27 (session e532d9f6)

**The framing above is half wrong, and the measurement that corrects it
makes the finding larger.** "The guard does not do what its docstring
says" is true; "so the guard is the defect" does not follow. Measured
on the pinned bootstrap `2026-08-27-555873e`:

**The binary carries `_perf` twice, and both copies shadow the tree.**

```
o/3p/cosmos/zip -sf o/bootstrap/cosmic | grep -cE '^\s+_perf/'      # 30 compiled modules at the zip root
o/3p/cosmos/zip -sf o/bootstrap/cosmic | grep -cE '\.tl/_perf/'     # 30 sources on the include path
```

The `.tl/` copy is what the type checker reads, which is the failure
3IUBNQZZ hit. The zip-root `_perf/*.lua` copy is what a RUNTIME
`require` reads, and that one is the bigger fact. A bare script run
from a tree root under that binary:

```lua
local compare = require("_perf.compare")
print(debug.getinfo(compare.format, "S").source)
```

```
$ o/bootstrap/cosmic /tmp/probe_resolve.lua
format source: @/zip/_perf/compare.lua
```

Run from the worktree whose `_perf/compare.tl` widens
`compare.format` to three parameters, the three-argument call
nonetheless **succeeds against the one-parameter embedded copy** — Lua
discards the extra arguments — printing the ordinary summary line. So
the tree's module was not merely out-voted; it was never loaded, and
nothing said so.

**Therefore the guard is FAITHFUL, not broken.** It reproduces on the
PR exactly the resolution the release lane has at runtime, which is
what a guard is for. What is wrong is its DOCSTRING — "`_perf.*`
resolves from the tree at cwd" is false in both contexts measured here
— and its remedy advice, which sends the reader to a tolerant map view
and a capability probe. That pattern is right for reaching a *cosmic*
API newer than the pin; it is not a remedy for a *sibling `_perf`*
signature change, where the honest reading is "the pinned binary is
checking you against its own copy of the module you just changed."

**And the consequence reaches past the guard.** `release.yml`'s
compare step runs the tree's `_perf/run.tl` under the PREVIOUS release
binary. `run.tl` itself is passed by path, so the tree's copy executes
— but every `require("_perf.harness")`, `require("_perf.compare")` and
`require("_perf.bench.*")` inside it resolves to that previous
release's embedded copy, by the measurement above. Whether the lane is
therefore measuring the tree's scenarios or the previous release's is
the question this item now turns on, and it is NOT yet established.

## What this item must settle, in order

1. **The release-lane picture, measured**: for `release.yml`'s compare
   step, which `_perf` files actually execute — tree or embed — for
   the harness, for `compare`, and for each bench module; whether a
   bench module added in the tree is seen or silently skipped; and
   whether `run.tl` enumerates benches by filesystem scan or by a
   require list. Until this is answered the fix cannot be chosen,
   because the two candidate fixes serve different defects.
2. **What governs precedence**, quoted from the searcher: whether
   `/zip` beating cwd is deliberate and configurable, or incidental.
3. **Then the fix**, which is one of:
   - the resolution is correct and only the guard's docstring and
     failure message are wrong — a documentation change, and
     `_perf` signature changes genuinely stage behind a release and a
     pin bump, a cost that should be written down where a session
     planning a `_perf` change will read it;
   - or the release lane is measuring the wrong code and the
     precedence is the defect, in which case the fix is in the
     searcher or the lane, not in the guard.

Route 3a leaves 3IUBNQZZ needing a two-PR-plus-a-release dance;
route 3b unblocks it in one PR. They are not the same item, so this
one stops at the evidence and the choice.

## Result — the resolution picture, measured 2026-08-27

Established against `o/bootstrap/cosmic` (the previous release,
content-wise) from a worktree whose `_perf/compare.tl` widens
`compare.format` from 1 parameter to 3 — a probe that tells the tree's
copy from an embedded one at a glance.

**Precedence has three seats, all in `cosmic/searcher.tl`.** The `/zip`
searcher inserts at `package.searchers` index 2; the TREE searcher
(`install_manifest`) inserts at 2 as well and thereby demotes `/zip` to
seat 3 — but only when the build engine hands it a manifest on argv
(`--modules MANIFEST`). The channel is deliberately argv and never an
environment variable, because an inherited path would answer a nested
project's imports out of the wrong tree; `docs/design/make/resolution.md`
records the removal of the old `TREE_LUA_PATH` escape hatch for that
reason. So the tree wins under `--make run` and loses everywhere else,
and `--include-dir` is not a lever: it feeds the type-check search path
only, never `package.searchers`.

| context | which `_perf` wins | proof |
|---|---|---|
| bare under the previous release (`release.yml:173`) | **binary embed** | `_perf.compare source=@/zip/_perf/compare.lua nparams=1` while the tree's is 3 |
| bare under the tree's own binary | binary embed — equal to the tree by construction, since that binary was just built from it | `nparams=3` |
| `--make run` (the documented local command) | **tree**, via the manifest | an OLD binary running `--make run _perf/gate.tl compare` prints the 3-param header; the same gate.tl bare under the same binary dies `wrong number of arguments (given 3, expects at most 1)` |
| `--make test _perf/skew_test.tl` | tree — which then SPAWNS a bare `--check types`, i.e. the first row's resolution | fails on the modified tree naming `_perf/gate.tl:128` and `_perf/run.tl:358` |

**The guard's docstring is false, and so is the correction above it.**
"`_perf.*` resolves from the tree at cwd" holds in NO context. The
guard nevertheless catches real failures, for a narrower reason than
it states: the entry script is tree-compiled because it is passed BY
PATH, and a module ABSENT from the binary's embed is tree-compiled
because nothing else answers the require. Both incidents the docstring
cites fit that narrower rule — `run.tl`'s `version_info` read was in
the path-given entry, and `literal_bench` was a new file.

**The larger finding: `release.yml:173` measures a MIX, and one class
of tree change is silently unmeasured on the baseline side.**
`_perf/run.tl` discovers benches by a filesystem scan of the tree
(`fs.find(BENCH_DIR, {glob = "*_bench.tl"})`) and then loads each by
`require`. So the NAMES come from the tree and the BYTES come from
whatever answers the require. Measured on a fake root carrying one
bench absent from every embed and one copy of an embedded bench with a
scenario renamed:

```
_perf.bench.probe_bench   from=@./_perf/bench/probe_bench.tl  scenarios=[probe_added_scenario]
_perf.bench.time_bench    from=@/zip/_perf/bench/time_bench.lua  scenarios=[time_format_date,time_format_iso8601]
```

- an **added** bench module is seen and runs the tree's copy — compiled
  by the OLD binary's Teal against the OLD embedded `cosmic.*`
  declarations, which is exactly the skew class the guard exists for.
  On the baseline side it reads as `new` in the compare, not as a
  baseline datum.
- a **changed** bench module runs the RELEASE's copy. The tree edit is
  invisible: `TREE_COPY_MARKER` never appears. **The guard cannot see
  this class at all**, because nothing fails to type-check — the old
  code simply runs instead of the new.

**Two corrections to this item's earlier framing**, both mine:

- The claim "the guard is faithful, so the guard is not the defect" is
  too generous. It is faithful to the baseline side's resolution for
  the two classes it can see, and blind to a third.
- A tree-vs-embed conclusion drawn in a worktree whose `o/bin/cosmic`
  is byte-identical to the pin proves nothing, because the two agree
  by construction. Every discriminating measurement here was run
  against a tree that actually differs from its binary.

Also worth knowing when reproducing: `o/bootstrap/cosmic`'s sha does
NOT match `bin/cosmic.pin`'s and that is not corruption — `bin/cosmic`
verifies the download against the pin and then `--assimilate`s it into
a native ELF, mutating the bytes. The pin sha is recorded beside it in
`o/bootstrap/cosmic.pin`.

**Not established**: whether a real release run has ever silently
diverged this way. The mechanism is proven; its historical incidence
needs release-run logs nobody has fetched.

## What is left to decide, narrowed

The evidence closes questions 1 and 2 of the list above. What remains
is the choice, and it is now a choice between three, not two:

1. **Document the cost.** The resolution stands; the guard's docstring
   and failure message are rewritten to say what actually happens, and
   the two-PR-plus-a-release dance for a `_perf` signature change is
   written down where a session planning one will read it. Cheapest,
   and leaves 3IUBNQZZ needing the dance.
2. **Give the baseline run the tree's `_perf`.** Hand `release.yml:173`
   a manifest so the tree searcher wins there too. This makes the
   baseline measure the tree's scenarios — which is what a compare
   wants — and unblocks 3IUBNQZZ in one PR. It also changes what the
   baseline number MEANS, so it needs its own argument: measuring an
   old binary with new harness code is a different experiment from
   what the lane runs today, and which one the gate should want is not
   obvious.
3. **Split the two.** Keep the baseline resolution as it is and fix
   only the guard's honesty, while filing the changed-bench blind spot
   as its own defect.

The changed-bench blind spot is real under 1 and 3 and should be its
own item either way.

## Change

Two files.

**1. `.github/workflows/release.yml`, the "compare against the previous
release" step.** Replace the bare baseline measurement

```
o/perf/prev/cosmic-lua _perf/run.tl --out o/perf/prev/perf.json
```

with a manifest run against the PREBUILT entry, so the previous release
binary measures the TREE's harness and the TREE's scenarios:

```
printf 'root %s\nbuild o\n' "$PWD" > o/perf/prev.modules
o/perf/prev/cosmic-lua --modules o/perf/prev.modules o/_perf/run.lua \
  --out o/perf/prev/perf.json
```

Nothing else in the step moves: `baseline.tl`, the SKIP branch, the
`chmod +x`, and the `gate.tl compare` invocation stand as written.

**Why this shape and not `--make run`.** Both work and both keep the
old binary as the interpreter. `--make run` additionally rebuilds
(+2.6 s warm) and, being a build, can in principle replace
`o/bin/cosmic` — the artifact this very workflow is about to publish
and has already measured. Observed identical on a fixpoint tree, but
"the old binary's compile happens to be byte-identical" is not a
property to stake a release on. The manifest form touches nothing:
`o/_perf/run.lua` and `o/_perf/bench/*.lua` already exist, built by the
candidate-side `--make run` at the step above, so the baseline run is
0.39 s and writes only its own results file.

`mod` lines are optional — `root` + `build` alone installs the tree
searcher, which resolves `<root>/o/<rel>.lua` then `<root>/<rel>.tl`
ahead of `/zip`, and that fall-through is what covers the bench modules
`run.tl` loads by COMPUTED require (`cosmic/searcher.tl`'s
`tree_searcher` names this case in its own doc comment).

The entry must be `o/_perf/run.lua`, not `_perf/run.tl`. Measured: with
the same manifest, the `.tl` entry still fails, because the dispatcher
type-checks the entry script through the binary's include path, which
finds `/zip/.tl/_perf/compare.tl` before any `require` runs.

**2. `_perf/skew_test.tl`, the header and the failure message.** The
docstring's claim that "`_perf.*` resolves from the tree at cwd" is
false in every context (Result above) and must go. Rewrite it to say
what is now true:

- the guard exists for a BARE run of the tree's `_perf` under an older
  binary, where the older binary's embedded declarations type-check
  what it compiles;
- after change 1 the release compare step is no longer such a run — but
  the `peers` job still is (`release.yml`, `./dl/cosmic-lua
  _perf/peers/run.tl --bin ./dl/cosmic-lua`), so the guard keeps its
  job and that lane is now the reason it exists;
- the failure message stops prescribing the tolerant-map-view remedy
  for what is in fact a sibling `_perf` signature change. Say both
  readings: a cosmic API newer than the pin takes the map view; a
  `_perf` signature the pinned binary declares differently is the
  binary checking you against its own copy.

## Non-goals

- **No change to the `peers` job.** It is still a bare run and still
  carries the skew class; converting it is the same edit against a
  different lane and a different artifact, and it is filed separately.
- **No `_perf` source change of any kind** — no harness, comparator,
  gate, scenario or `check()` edit. The one `_perf` file this touches
  is `skew_test.tl`, and only its prose.
- No threshold, bar or noise-floor change. In particular
  `codec_base64_roundtrip_64k` keeps its floor: 3IU0GxoA's evidence
  makes that scenario look MORE stable within a session, not less.
- No decision record. Nothing settled is being reversed; a lane is
  being made to measure what it always claimed to measure.
- No `--make run` in the baseline step, for the artifact-replacement
  reason above.
- No change to `bin/cosmic.pin`, `cosmic/searcher.tl`, `_make/**`, or
  the `--modules` format.
- No attempt to guard the surface this newly exposes (below). Naming it
  is this item's job; guarding it is not.

## What this newly exposes, stated rather than guarded

After change 1 the tree's `cosmic.*` Lua runs on the previous release's
`cosmo.*` C bindings, because the manifest root covers `cosmic/**` too.
A tree `cosmic.*` module reaching a `cosmo.*` binding the previous
release does not carry fails at runtime on the baseline side. Measured
on this tree it is clean — all 48 scenarios ran, exit 0, no error lines
— but that is one observation, not a guard, and `skew_test` does not
cover it (it checks `_perf/**` only, and only statically). This is the
same class the pin bump procedure already manages for `cosmo.*`, and it
is named here so the next failure is recognised rather than
investigated from scratch.

## Acceptance

`o/bootstrap/cosmic` stands in for the previous release throughout: it
is content-wise the pinned release, and its sha differs from
`bin/cosmic.pin`'s only because `bin/cosmic` `--assimilate`s it after
verifying the download (the pin sha is recorded in
`o/bootstrap/cosmic.pin`).

- `bin/cosmic --make ci` ends `ci: PASS`.

- **The new command shape works and measures the OLD binary.** After
  `bin/cosmic --make build`:

  ```
  printf 'root %s\nbuild o\n' "$PWD" > o/perf/prev.modules
  o/bootstrap/cosmic --modules o/perf/prev.modules o/_perf/run.lua \
    --out o/perf/prev-probe.json --samples 1 --min-secs 0.05
  ```

  exits 0, and the results file's `meta.bin_sha` equals
  `sha256sum o/bootstrap/cosmic`, NOT `sha256sum o/bin/cosmic`. Both
  sha values quoted in the PR so the reviewer can see they differ.

- **It measures the TREE's `_perf`, not the binary's.** The same
  invocation with a probe entry, or a `--only` run, reports
  `_perf.harness` loading from a path under the repo root rather than
  `@/zip/_perf/harness.lua`. Today the bare form
  (`o/bootstrap/cosmic _perf/run.tl …`) reports `@/zip/_perf/harness.lua`
  — quote both, they are the before and after of this whole item.

- **The scenario set is the tree's.** The probe run's scenario count
  equals the count the candidate-side `bin/cosmic --make run
  _perf/run.tl` reports on the same tree.

- **The guard still passes and still means something.**
  `bin/cosmic --make test _perf/skew_test.tl` ends `test: PASS`, and
  `grep -c 'resolves from the tree at cwd' _perf/skew_test.tl` → `0`.

- **The workflow ratchet is clean.**
  `bin/cosmic --make test _build/workflows_test.tl` ends `test: PASS`.

- The diff is exactly two files:
  `git diff origin/main --name-only` → `.github/workflows/release.yml`
  and `_perf/skew_test.tl`, nothing else. `git diff origin/main -- _perf
  | grep -c '^[+-]' ` counts only comment and string lines — no
  executable `_perf` line changes.

## Enablement

None needed, and measured rather than asserted. The three facts the
Change rests on are each proved in the Result and the notes above:
`run` is absent from `_make/converge.tl`'s `GATES`, so no verb here
re-execs; `--modules` is a real documented flag (`sys/help.md`,
`_cli/args.tl`) whose `mod` lines are optional; and the prebuilt
`o/_perf/run.lua` the new command names is already produced by the
candidate-side `--make run` that precedes it in the same job. The
`_perf/skew_test.tl` shadowing that bounced 3IUBNQZZ does not reach
this slice — the only `_perf` file it touches is that test's own prose,
and no `_perf` signature moves.
