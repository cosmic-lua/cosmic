## Goal

G6 — the defining paths, ratcheted: the skew guard must fail exactly on
the `_perf` files the release compare step really loads from the tree,
so an ordinary `_perf` refactor is landable in one PR and a real
release-lane break still cannot merge.

## Evidence

Measured 2026-08-27 against this repo at `859eb6ae` (clean tree), with
the pinned bootstrap `o/bootstrap/cosmic` (`bin/cosmic.pin` names
release `2026-08-27-555873e`). Every command below is runnable from the
repo root; the scratch ones write only under a temp directory.

**The pinned binary answers for `_perf` twice over.** It ships both the
compiled modules and their sources:

```
$ unzip -l o/bootstrap/cosmic | awk '{print $4}' | grep -c '^_perf/'
30
$ unzip -l o/bootstrap/cosmic | awk '{print $4}' | grep -c '^\.tl/_perf/'
30
$ find _perf -name '*.tl' ! -name '*_test.tl' | wc -l
30
```

`/zip/?.lua` is first in `package.path` and `/zip/.tl` is include dir 3
of 4 in `cosmic/_teal_engine.tl`'s `default_include_dirs` (lines 76-86),
both ahead of the cwd patterns. So in a BARE run the binary's copy wins
for every `_perf` module it carries — at run time and at check time.
Reproduced with a scratch tree holding only a broken sibling:

```
$ D=$(mktemp -d) && mkdir -p "$D/_perf/bench" \
  && echo 'this is not valid teal at all !!!' > "$D/_perf/bench/json_bench.tl" \
  && printf 'local ok, mod = pcall(require, "_perf.bench.json_bench")\nprint("ok=" .. tostring(ok))\n' > "$D/probe.tl" \
  && (cd "$D" && /home/user/cosmic/o/bootstrap/cosmic probe.tl)
ok=true
```

The tree file is never opened. `--include-dir .` flips the CHECKER to
the tree but not the runtime searcher (`cosmic/searcher.tl` calls
`teal.search_module(name)` with no extras, so it always gets the
defaults) — measured: with `--include-dir .` a scratch `_perf/compare.tl`
whose `format` returns `"TREE-BODY"` still printed the embedded body's
`0 scenarios: …` line.

**So the guard's docstring is wrong and its sweep is 29/30 inert.**
`_perf/skew_test.tl:1-25` claims "`_perf.*` resolves from the tree at
cwd"; it does not. release.yml names exactly one bare `_perf` entry
(`.github/workflows/release.yml:173`):

```
o/perf/prev/cosmic-lua _perf/run.tl --out o/perf/prev/perf.json
```

`_perf/run.tl` is the only tree file that lane compiles, because it is
named by PATH. Everything it requires comes from the previous release's
payload. `_perf/gate.tl` is never a bare entry — release.yml:174 runs it
`o/bin/cosmic --make run _perf/gate.tl`, where `_cli/build/modules.tl`'s
`--modules` manifest makes the tree answer (`docs/design/make/
resolution.md`: "In a project, the tree answers. Outside one, the binary
does."). An earlier session recorded the same split independently:
3ITdGe7O's evidence calls its `_perf/gate.tl:77` finding "INERT: the
workflow only ever runs gate.tl tree-resolved via `--make run`."

**Both halves of 3IUBNQZZ's failure reproduced**, in a scratch mirror
that widens `compare.format` with two optional parameters and calls it
with three arguments (the shape 3IUBNQZZ needs):

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

(exit 1; one `hint:` line after each error elided.) The four `gate.tl`
errors are spurious. The one `run.tl` error is REAL —
the same mirror, run the way release.yml runs it, dies before it
measures anything:

```
$ (cd "$D" && /home/user/cosmic/o/bootstrap/cosmic _perf/run.tl --help)
cosmic-lua: _perf/run.tl:358:23: error: wrong number of arguments (given 3, expects at most 1)
```

That is the whole finding: the guard is not too strict, it is aimed at
the wrong set. Today's sweep is green (`COSMIC_COVERAGE=0
o/bootstrap/cosmic --check types $(find _perf -name '*.tl' !
-name '*_test.tl' | sort | tr '\n' ' ')` exits 0), so this slice changes
the subject, not the verdict.

**The classifier the fix needs already works under the pin.** Run under
`o/bootstrap/cosmic` itself, which type-checks its entry with the PINNED
checker — so this also proves `cosmic.zip` is old enough to use here:

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
2. Rewrite the module docstring to state the measured rule instead of
   the false one: a bare run resolves every module the binary carries
   from the binary (`/zip/<path>.lua` first in `package.path`,
   `/zip/.tl/<path>` via include dir 3), so the release compare step
   compiles from the TREE only (a) the path release.yml names and
   (b) any `_perf` source that release does not carry. Cite
   `docs/design/make/resolution.md`'s rule sentence and
   `.github/workflows/release.yml:173`. Keep the existing paragraph
   about the pin trailing published releases — it is what makes the
   classifier conservative: the pin carries a SUBSET of the previous
   release's files, so "absent from the pin" over-approximates "absent
   from the previous release", and the sweep can only check too much,
   never too little.
3. Add `local zip = require("cosmic.zip")` and a const
   `ENTRIES: {string} = {"_perf/run.tl"}` — the paths release.yml passes
   to a bare `o/perf/prev/cosmic-lua`, hardcoded rather than parsed out
   of the workflow's shell block, with step 6 as the drift guard.
4. Replace `perf_sources()` with `bare_loaded_sources(): {string}`:
   open the bootstrap with `check.must(zip.open(BOOTSTRAP))` (never a
   silent skip — an unreadable payload means the sweep classified
   nothing), then return, sorted and de-duplicated, every path in
   `ENTRIES` plus every non-test `_perf/**` source the archive does not
   carry. "Carries" means `archive:stat(path:gsub("%.tl$", ".lua"))` or
   `archive:stat(".tl/" .. path)` returns non-nil — both payload
   positions, because either one wins over the tree. Close the archive
   before returning. Keep the existing `fs.find("_perf", {glob = "*.tl"})`
   walk and the `_test%.tl$` exclusion as the candidate set.
5. Rename the existing test to
   `test_bare_loaded_sources_type_check_under_the_pinned_bootstrap` and
   feed it `bare_loaded_sources()`. Leave the child invocation exactly
   as it is — `{BOOTSTRAP, "--check", "types", …}` with
   `COSMIC_COVERAGE=0` and no include-dir flag — because siblings must
   resolve from the binary, which is how the bare lane resolves them.
   Keep the `assert(fs.is_file(BOOTSTRAP), …)` guard and the
   `assert(#files > 0, …)` guard (the second now means "the entry set is
   never empty").
   Rewrite its failure message to name the two live cases and their
   remedies: for a file the pinned release lacks, a cosmic API newer
   than the pin, reached through a tolerant map view plus a capability
   probe (`_perf/bench/literal_bench.tl`); for an entry in `ENTRIES`, a
   sibling `_perf` API the pinned release does not declare, whose
   remedies are the same tolerant-call pattern or staging the change
   behind a release and a `bin/cosmic.pin` bump. Drop the current
   sentence that prescribes the map-view pattern for every failure.
6. Add `test_release_yml_names_only_the_declared_bare_entries()`: read
   `.github/workflows/release.yml` with `check.must(fs.read(...))`, and
   for every `o/perf/prev/cosmic%-lua%s+(%S+)` capture in it assert the
   captured path is in `ENTRIES`; then assert each `ENTRIES` path was
   captured at least once, so the test cannot pass because the pattern
   went dead.
7. Add `test_bare_loaded_sources_excludes_what_the_pin_carries()`:
   assert `_perf/run.tl` is in `bare_loaded_sources()`, and that
   `_perf/gate.tl` is not — guarded by a precondition assert that the
   pinned bootstrap actually carries `_perf/gate.tl`, so the negative
   assertion cannot pass vacuously when a future pin drops the file.
8. Call each new `test_*` on the line after its `end`, per AGENTS.md.

## Non-goals

- **Do not add `--include-dir .` or `--modules` to the guard's child.**
  It makes every case pass (measured above) by checking a resolution
  order the bare lane never uses, and it would have let #1415 and
  #1420 through.
- **Do not touch any other `_perf` file.** Not `_perf/compare.tl`,
  `_perf/gate.tl`, `_perf/run.tl`, `_perf/harness.tl` or any bench
  module. The widening in 3IUBNQZZ is that item's diff, not this one.
- **Do not change `.github/workflows/release.yml`.** In particular do
  not switch line 173 to the binary's own embedded entry
  (`o/perf/prev/cosmic-lua /zip/.tl/_perf/run.tl`, which does run) — that
  changes what the baseline measures and is a separate decision.
- **Do not change module resolution.** `cosmic/_teal_engine.tl`'s
  `default_include_dirs` order, `cosmic/searcher.tl`, and
  `docs/design/make/resolution.md`'s rule are settled and load-bearing
  for the whole build; this slice reads them and adapts to them.
- **Do not soften either loud failure into a skip** — neither the
  missing bootstrap nor an unreadable payload.
- **Do not change verdict-line formats** (`test: PASS (N file[s])`) or
  the `--- reads:` grammar.
- No new CLI flag, no new module, no change to `_perf/perf_test.tl`.

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
- `head -1 _perf/skew_test.tl` is
  `--- reads: _perf o/bootstrap/cosmic .github/workflows/release.yml`.
- `wc -l < _perf/skew_test.tl` is at most `170` (today: `71`).
- `bin/cosmic --check lint _perf/skew_test.tl` exits 0.

## Enablement

**none needed — this is landable in ONE PR, with no release+pin
staging.** The cold-build rule binds a change that needs the TREE's own
checker or patch set; this one needs neither. The diff is confined to a
single `*_test.tl` file, changes no `_perf` module signature, and uses
only APIs the pinned bootstrap already declares — `cosmic.zip.open`,
`Archive:stat`, `Archive:close`, `cosmic.fs`, `cosmic.child`,
`cosmic.env`, `cosmic.check` — verified by running the classifier probe
under `o/bootstrap/cosmic` itself, which type-checks its entry with the
pinned checker (output in Evidence). `_perf/skew_test.tl` is a
`*_test.tl`, so the guard does not sweep itself.

What it unblocks, precisely: 3IUBNQZZ's `blocked_by` edge cites this
item because widening `compare.format` fails the guard at both
`_perf/gate.tl` and `_perf/run.tl`. This slice removes the four
`gate.tl` failures — they are checks of a configuration that never runs.
It does NOT remove `_perf/run.tl:358`, which is a real break of
release.yml's compare step (reproduced above), so 3IUBNQZZ must still
either reach the widened `compare.format` from `run.tl` through the
tolerant map-view plus capability-probe pattern that
`_perf/bench/literal_bench.tl` already uses, or stage its `run.tl` call
site behind a release and a `bin/cosmic.pin` bump. That is a fact about
3IUBNQZZ's own Change, and re-judging its edge belongs to whoever pulls
it — this slice does not edit that item.

Predicted wrong turns and the countermeasures already in this spec:

- reaching for `--include-dir .` because it makes the red go away — the
  first Non-goal names it, and an Acceptance grep pins it at 0.
- writing the `_perf/gate.tl` exclusion as an assertion that passes
  vacuously once a pin no longer carries the file — step 7 requires the
  precondition assert (the failure class board item 3ICInA37 records).
- letting the hardcoded `ENTRIES` drift when release.yml changes — step
  6 turns that into a test failure instead of a silently misaimed guard.
