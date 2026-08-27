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

## Refinement — the pick, 2026-08-27

Everything above is preserved from the prior refinement (board commit
`a4839510`), which a last-write-wins `spec` write from a concurrent
session briefly replaced; this document restores it and continues it.
`gitboard spec` keeps no trail, so the pointer is written here instead.

**The pick is route 3 of the three above: split.** Keep the baseline
lane's resolution exactly as it is, fix only the guard's honesty and its
subject, and file the changed-bench blind spot as its own item.

Why not route 1 (document the cost and stop): the cost as stated is not
the real one. Of the five errors a `compare.format` widening produces,
four are checks of a configuration that never runs; only the entry
script's is real. "A `_perf` signature change stages behind a release"
is therefore false as a general rule, and writing it down would
institutionalise a tax the tree does not actually levy.

Why not route 2 (hand `release.yml:173` a manifest): it changes what the
baseline number means — measuring an old binary with new harness code is
a different experiment — and, as the section above says, which
experiment the gate should want is not obvious. That argument deserves
its own item and its own evidence; it must not ride in on a test fix.

Two independent confirmations of the inert half, measured 2026-08-27
against this repo at `859eb6ae` (clean tree), pinned bootstrap
`2026-08-27-555873e`, in a scratch mirror rather than the worktree so
nothing committed is touched:

```
$ D=$(mktemp -d) && cp -r _perf "$D/" && cd "$D" \
  && sed -i 's|local function format(deltas: {pt.Delta}): string|local function format(deltas: {pt.Delta}, _a?: integer, _b?: integer): string|' _perf/compare.tl \
  && sed -i 's|  format: function(deltas: {pt.Delta}): string|  format: function(deltas: {pt.Delta}, _a?: integer, _b?: integer): string|' _perf/compare.tl \
  && sed -i 's|print(compare.format(deltas))|print(compare.format(deltas, 1, 2))|' _perf/run.tl _perf/gate.tl \
  && COSMIC_COVERAGE=0 /home/user/cosmic/o/bootstrap/cosmic --check types _perf/compare.tl _perf/gate.tl _perf/run.tl
Type check passed: _perf/compare.tl
_perf/gate.tl:143:23: error: wrong number of arguments (given 3, expects 1)
_perf/gate.tl:199:23: error: wrong number of arguments (given 3, expects 1)
_perf/gate.tl:250:23: error: wrong number of arguments (given 3, expects 1)
_perf/gate.tl:290:23: error: wrong number of arguments (given 3, expects 1)
_perf/run.tl:358:23: error: wrong number of arguments (given 3, expects 1)
```

(exit 1; one `hint:` line after each error elided. Line numbers differ
from the table above because that run carried 3IUBNQZZ's real diff and
this one is a sed mirror of the same shape.) The one live error, run the
way `release.yml:173` runs it, kills the lane before it measures:

```
$ (cd "$D" && /home/user/cosmic/o/bootstrap/cosmic _perf/run.tl --help)
cosmic-lua: _perf/run.tl:358:23: error: wrong number of arguments (given 3, expects at most 1)
```

And the classifier the fix needs is already old enough to use, proven by
running it under the pinned bootstrap itself, which type-checks its
entry with the pinned checker:

```
$ D=$(mktemp -d) && cat > "$D/zprobe.tl" <<'EOF'
local zip = require("cosmic.zip")
local a = assert(zip.open("o/bootstrap/cosmic"))
for _, n in ipairs({"_perf/gate.lua", ".tl/_perf/gate.tl", ".tl/_perf/nope.tl"}) do
  print(n .. " -> " .. tostring(a:stat(n) ~= nil))
end
local _ok, _e = a:close()
EOF
$ o/bootstrap/cosmic "$D/zprobe.tl"
_perf/gate.lua -> true
.tl/_perf/gate.tl -> true
.tl/_perf/nope.tl -> false
```

Today's sweep is green — `COSMIC_COVERAGE=0 o/bootstrap/cosmic --check
types $(find _perf -name '*.tl' ! -name '*_test.tl' | sort | tr '\n' ' ')`
exits 0 — so this slice changes the guard's subject, not its verdict.
And the pin currently carries all 30 non-test `_perf` sources
(`unzip -l o/bootstrap/cosmic | awk '{print $4}' | grep -c '^_perf/'` is
30, `grep -c '^\.tl/_perf/'` is 30, `find _perf -name '*.tl' !
-name '*_test.tl' | wc -l` is 30), so the narrowed sweep checks exactly
one file today and grows the moment a `_perf` source is added.

## Goal

G6 — the defining paths, ratcheted: the skew guard fails on exactly the
`_perf` files the release compare step compiles from the tree, so an
ordinary `_perf` refactor is landable in one PR and a real release-lane
break still cannot merge.

## Change

`_perf/skew_test.tl` only. Today: `wc -l < _perf/skew_test.tl` is 71
(429 lines of headroom under the 500-line cap) and
`grep -c '^local function test_' _perf/skew_test.tl` is 1.

1. Header: extend the reads declaration to
   `--- reads: _perf o/bootstrap/cosmic .github/workflows/release.yml`
   (`_make/imports.tl`'s `reads_scan` splits on whitespace and
   `reads_of_file` fails loudly on a path that does not exist, so the
   new entry joins the test's content key and makes it re-run when the
   workflow changes).
2. Rewrite the module docstring to the narrower rule the table above
   establishes: a bare run resolves every module the binary carries from
   the binary (`/zip/<path>.lua` at `package.searchers` seat 2,
   `/zip/.tl/<path>` on the checker's include path), so the release
   compare step compiles from the TREE only (a) the path
   `.github/workflows/release.yml:173` names and (b) any `_perf` source
   that release does not carry. Cite `docs/design/make/resolution.md`'s
   rule sentence. Keep the existing paragraph about the pin trailing
   published releases: it is what makes the classifier conservative,
   since the pin carries a SUBSET of the previous release's files, so
   "absent from the pin" over-approximates "absent from the previous
   release" and the sweep can only check too much, never too little.
   State the blind spot in the same docstring — a CHANGED module the
   release carries runs the release's copy, which no type check can
   see — and point at the item filed for it.
3. Add `local zip = require("cosmic.zip")` and a const
   `ENTRIES: {string} = {"_perf/run.tl"}` — the paths release.yml passes
   to a bare `o/perf/prev/cosmic-lua`, hardcoded rather than parsed out
   of the workflow's shell block, with step 6 as the drift guard.
4. Replace `perf_sources()` with `bare_loaded_sources(): {string}`:
   open the bootstrap with `check.must(zip.open(BOOTSTRAP))` — never a
   silent skip, since an unreadable payload means the sweep classified
   nothing — then return, sorted and de-duplicated, every path in
   `ENTRIES` plus every non-test `_perf/**` source the archive does not
   carry. "Carries" means `archive:stat(path:gsub("%.tl$", ".lua"))` or
   `archive:stat(".tl/" .. path)` returns non-nil — both payload
   positions, because either one answers ahead of the tree. Close the
   archive before returning. Keep the existing
   `fs.find("_perf", {glob = "*.tl"})` walk and the `_test%.tl$`
   exclusion as the candidate set.
5. Rename the existing test to
   `test_bare_loaded_sources_type_check_under_the_pinned_bootstrap` and
   feed it `bare_loaded_sources()`. Leave the child invocation exactly
   as it is — `{BOOTSTRAP, "--check", "types", …}` with
   `COSMIC_COVERAGE=0` and no include-dir flag — because siblings must
   resolve from the binary, which is how the bare lane resolves them.
   Keep the `assert(fs.is_file(BOOTSTRAP), …)` guard and the
   `assert(#files > 0, …)` guard, the second now meaning "the entry set
   is never empty". Rewrite its failure message to name the two live
   cases and their remedies: for a file the pinned release lacks, a
   cosmic API newer than the pin, reached through a tolerant map view
   plus a capability probe (`_perf/bench/literal_bench.tl`); for an
   entry in `ENTRIES`, a sibling `_perf` API the pinned release does not
   declare, whose remedies are the same tolerant-call pattern or staging
   that call site behind a release and a `bin/cosmic.pin` bump. Drop the
   current sentence that prescribes the map-view pattern for every
   failure.
6. Add `test_release_yml_names_only_the_declared_bare_entries()`: read
   `.github/workflows/release.yml` with `check.must(fs.read(...))`, and
   for every `o/perf/prev/cosmic%-lua%s+(%S+)` capture assert the
   captured path is in `ENTRIES`; then assert each `ENTRIES` path was
   captured at least once, so the test cannot pass because the pattern
   went dead.
7. Add `test_bare_loaded_sources_excludes_what_the_pin_carries()`:
   assert `_perf/run.tl` is in `bare_loaded_sources()` and `_perf/gate.tl`
   is not — guarded by a precondition assert that the pinned bootstrap
   actually carries `_perf/gate.tl`, so the negative assertion cannot
   pass vacuously when a future pin drops the file.
8. Call each new `test_*` on the line after its `end`, per AGENTS.md.

## Non-goals

- **Do not add `--include-dir .` or `--modules` to the guard's child.**
  `--include-dir .` makes every case pass by checking a resolution order
  the bare lane never uses, and it would have let #1415 and #1420
  through. (Measured: with `--include-dir .` the mirror above
  type-checks clean.)
- **Do not touch any other `_perf` file.** Not `_perf/compare.tl`,
  `_perf/gate.tl`, `_perf/run.tl`, `_perf/harness.tl` or any bench
  module. The widening in 3IUBNQZZ is that item's diff, not this one.
- **Do not change `.github/workflows/release.yml`** — that is route 2,
  deferred with its reason above. In particular do not switch line 173
  to the binary's own embedded entry
  (`o/perf/prev/cosmic-lua /zip/.tl/_perf/run.tl`, which does run).
- **Do not fix the changed-bench blind spot here.** It gets its own
  item; this slice only names it in the docstring.
- **Do not change module resolution.** `cosmic/searcher.tl`,
  `cosmic/_teal_engine.tl`'s `default_include_dirs` order and
  `docs/design/make/resolution.md`'s rule are settled and load-bearing
  for the whole build; this slice reads them and adapts to them.
- **Do not soften either loud failure into a skip** — neither the
  missing bootstrap nor an unreadable payload.
- **Do not change verdict-line formats** (`test: PASS (N file[s])`) or
  the `--- reads:` grammar. No new CLI flag, no new module, no change to
  `_perf/perf_test.tl`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _perf/skew_test.tl` ends `test: PASS (1 file)`.
- `COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types _perf/run.tl`
  prints `Type check passed: _perf/run.tl` and exits 0 — the entry stays
  guarded.
- `grep -c '^local function test_' _perf/skew_test.tl` prints `3`
  (today: `1`).
- `grep -c 'include-dir' _perf/skew_test.tl` prints `0` (today: `0`) —
  the walled-off route stayed walled off.
- `head -1 _perf/skew_test.tl` prints
  `--- reads: _perf o/bootstrap/cosmic .github/workflows/release.yml`.
- `wc -l < _perf/skew_test.tl` is at most `170` (today: `71`).
- `bin/cosmic --check lint _perf/skew_test.tl` exits 0 (today: prints
  `Style check passed: _perf/skew_test.tl`).

## Enablement

**none needed — landable in ONE PR, with no release+pin staging.** The
cold-build rule binds a change that needs the TREE's own checker or
patch set; this one needs neither. The diff is confined to a single
`*_test.tl`, changes no `_perf` module signature, and uses only APIs the
pinned bootstrap already declares — `cosmic.zip.open`, `Archive:stat`,
`Archive:close`, `cosmic.fs`, `cosmic.child`, `cosmic.env`,
`cosmic.check` — verified by running the classifier probe under
`o/bootstrap/cosmic` itself (output above). `_perf/skew_test.tl` is a
`*_test.tl`, so the guard never sweeps itself.

What it unblocks, precisely: 3IUBNQZZ's `blocked_by` edge cites this
item because widening `compare.format` fails the guard at both
`_perf/gate.tl` and `_perf/run.tl`. This slice removes the four
`gate.tl` failures. It does NOT remove `_perf/run.tl:358`, which is a
real break of release.yml's compare step, so 3IUBNQZZ must still either
reach the widened `compare.format` from `run.tl` through the tolerant
map-view plus capability-probe pattern `_perf/bench/literal_bench.tl`
already uses, or stage that one call site behind a release and a
`bin/cosmic.pin` bump. That is a fact about 3IUBNQZZ's own Change, and
re-judging its edge belongs to whoever pulls it; this slice does not
edit that item.

Predicted wrong turns and the countermeasures already in this spec:

- reaching for `--include-dir .` because it makes the red go away — the
  first Non-goal names it and an Acceptance grep pins it at 0.
- writing the `_perf/gate.tl` exclusion as an assertion that passes
  vacuously once a pin no longer carries the file — step 7 requires the
  precondition assert (the failure class board item 3ICInA37 records).
- letting the hardcoded `ENTRIES` drift when release.yml changes — step
  6 turns that into a test failure instead of a silently misaimed guard.
