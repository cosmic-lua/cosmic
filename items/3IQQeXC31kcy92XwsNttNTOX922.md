## Goal
G3 — an honest type layer, under `3IOuS3IE` (the `any`-declaring sites of
`3IOK4SZH`'s dynamic-value boundary). This is the guard half: the twelve
sites where the value arrives as `any` from a boundary the code does not
own (a `require` the checker cannot resolve, a `pcall`ed chunk, a callback
context the API deliberately types `any`) and the site ALREADY names the
type it wants, one line later, in an `as`. Each closes with `is` — no
signature moves, no API changes.

## Change
At each site below, replace the `as` cast with an `is` guard against the
type the site already names, and give the negative branch the failure the
surrounding code already has a shape for (a `nil, msg` return in library
code, an `assert` in a test). Over `any`, `x is Rec` compiles to one
`type(x) == "table"` test and `x is string` to one `type(x) == "string"`
test — the same mechanism PR #1382 used for `_cli/main_handlers.tl` and
`cosmic/init.tl`, and the one AGENTS.md names ("Use `is` for dispatch past
nil … also dispatch over `any`"). No cast replaces any of the twelve.

Sites, measured 2026-08-25 against `47adef2c` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`. Every
record named below is already declared at the site; nothing new is
declared except where stated.

**Library (4 casts, 3 files).**
- `cosmic/quicksand/box/init.tl:43` — `require("cosmic.quicksand") as
  CapsModule` inside `caps()`. `CapsModule` is declared at `:38–40`. Guard
  it; when the require does not yield the record, return the empty
  `types.Capabilities` the caller already handles rather than indexing a
  non-table. (205 lines, 295 of headroom.)
- `cosmic/quicksand/box/init.tl:150` — `require("cosmic.quicksand.box.run")
  as RunModule` inside `run()`. `RunModule` is declared at `:137–139`. The
  function returns `integer | nil, string`, so the negative branch is a
  `nil, "quicksand: box run module unavailable"`.
- `cosmic/quicksand/box/run.tl:68` — the same lazy `require("cosmic.quicksand")`,
  taken to break the umbrella's re-export cycle (the comment at `:66–67`
  says so and stays). Guard it; the branch it feeds only decides whether
  `CLONE_NEWPID` joins `flags`, so a failed guard leaves `flags` unchanged.
  (342 lines, 158 of headroom.)
- `cosmic/doc/query.tl:39` — `result as DocIndex`, where `result` is the
  value of a `pcall(chunk)` over the embedded index. The function already
  returns `nil, string` on both preceding failures, so the guard's negative
  branch is `return nil, "index is not a doc index"`. **`cosmic/doc/query.tl`
  is 479 lines — 21 of headroom under the 500-line cap** (`wc -l
  cosmic/doc/query.tl`); the change is line-neutral to +3 and must stay
  under it, which is why `Acceptance` measures it.

**Tests (8 casts, 6 files).** Each of these is a test asserting on a value
it created or a module it required; the guard replaces the cast and the
`assert` message names what did not arrive.
- `_docs/publish_test.tl:58` — `require("_docs.publish") as PublishModule`;
  `PublishModule` is declared at `:8–11`.
- `cosmic/searcher_test.tl:41` — `require(name) as {string: integer}`,
  where `name` is a fixture module minted by the test. `is {string:
  integer}` is the map-type form AGENTS.md names.
- `_perf/perf_test.tl:49` — `mod as pt.BenchModule` from a
  `pcall(require, name)` over discovered bench modules. The two `assert`s
  on the next lines already check `scenarios`/`cleanup`; the guard goes
  in front of them.
- `_perf/run.tl:165` — `mod as pt.BenchModule` in `load_module`, which
  returns `pt.BenchModule, string`: the negative branch is the `nil, name
  .. ": not a bench module (missing scenarios())"` the next `if` already
  produces.
- `cosmic/fs/path_test.tl:180` — `c as WalkContext` inside the
  `fs.visit` visitor. `fs.visit`'s context parameter is `any` by contract
  and does not move (see Non-goals).
- `_perf/harness_test.tl:16`, `:40`, `:43` — `res as string`, `(ctx as
  {string: string}).token`, `res as string`. The harness types scenario
  contexts and results `any` by contract; these are the test's own values,
  so `is string` / `is {string: string}` narrow them.

**The ratchet.** `_build/casts_baseline.tl` is a committed floor whose rows
count every cast in a file, not only the `from any` ones. When the gate
complains, run exactly the command its failure message prints —
`bin/cosmic --make run _build/casts.tl --baseline` — and commit the result;
no gate is weakened any other way. The expected row moves (today's totals
from `grep -c -- "-- cast:" <file>`, and `[path] = n` rows read from the
floor):

| file | row today | row after |
| --- | --- | --- |
| `cosmic/quicksand/box/init.tl` | `= 3` | `= 1` |
| `cosmic/quicksand/box/run.tl` | `= 2` | `= 1` |
| `cosmic/doc/query.tl` | `= 1` | row absent |
| `_docs/publish_test.tl` | `= 1` | row absent |
| `cosmic/searcher_test.tl` | `= 2` | `= 1` |
| `_perf/perf_test.tl` | `= 2` | `= 1` |
| `_perf/run.tl` | `= 2` | `= 1` |
| `cosmic/fs/path_test.tl` | `= 1` | row absent |
| `_perf/harness_test.tl` | `= 3` | row absent |

A row at zero is absent from the floor by construction — `_build/casts.tl`
emits only files with at least one cast — so four rows disappear rather
than reading `= 0`.

## Non-goals
- **No signature moves.** `fs.visit`'s `any` context, `_perf.harness`'s
  `any` scenario context and result, and the `_perf.types` records stay
  exactly as declared. This slice guards at the point of use; making a
  declaration honest is its sibling `3IOuS3IE` child and, for `fs.visit`,
  `3ILxnhaK`.
- **`_perf/run.tl:132` stays.** `rawget(arg, -1) as string` sits inside an
  `or` chain, so closing it restructures an expression rather than adding a
  guard; it is not this slice's uniform shape. `_perf/run.tl` therefore
  ends with one `from any` cast, not zero.
- **The lazy requires stay lazy.** `cosmic/quicksand/box/run.tl:68` and
  `cosmic/quicksand/box/init.tl:150` are deliberate cycle breaks; do not
  hoist either to a top-level `require`, and do not touch the comments
  that say why.
- **No new public module and no new export.** `_build/public_surface_baseline.tl`
  must not move.
- **Do not touch the other 87 `from any` casts.** 99 lines carry that
  reason today across 41 files (`git ls-files '*.tl' | xargs grep -h --
  "-- cast: " | grep -c "from any"`; two of the 99 are string literals in
  `_build/casts_test.tl` that the lexer-based counter does not count).
  Only the twelve named above close here.
- **Do not touch `cosmic/sqlite/**` or `cosmic/fetch/**`.** They are the
  sibling child's files, and both slices rewrite `_build/casts_baseline.tl`
  — keeping the source files disjoint keeps the conflict to that one
  regenerated file.
- **Do not edit `docs/design/casts.md`** (a stale snapshot; `3IQC4GeO`
  owns it).

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: .*from any" cosmic/quicksand/box/init.tl
  cosmic/quicksand/box/run.tl cosmic/doc/query.tl _docs/publish_test.tl
  cosmic/searcher_test.tl _perf/perf_test.tl cosmic/fs/path_test.tl
  _perf/harness_test.tl` prints `0` for each of the eight (today: `2`, `1`,
  `1`, `1`, `1`, `1`, `1`, `3`).
- `grep -c -- "-- cast: .*from any" _perf/run.tl` prints `1` (today `2`).
- `grep -c -- " as " cosmic/quicksand/box/init.tl` does not exceed today's
  value (`3`) — no cast is traded for another.
- `grep -n '"cosmic/doc/query.tl"\|"_docs/publish_test.tl"\|"cosmic/fs/path_test.tl"\|"_perf/harness_test.tl"' _build/casts_baseline.tl`
  prints nothing (today it prints four rows).
- `grep -n '"cosmic/quicksand/box/init.tl"\|"cosmic/quicksand/box/run.tl"\|"cosmic/searcher_test.tl"\|"_perf/perf_test.tl"\|"_perf/run.tl"' _build/casts_baseline.tl`
  shows `= 1` on each of the five (today: `3`, `2`, `2`, `2`, `2`).
- `wc -l cosmic/doc/query.tl` reports at most 500 (today `479`).
- `bin/cosmic --make test cosmic/doc/query_test.tl cosmic/searcher_test.tl
  cosmic/fs/path_test.tl _docs/publish_test.tl _perf/perf_test.tl
  _perf/harness_test.tl` ends `test: PASS (6 files)`.
- `bin/cosmic --make test cosmic/quicksand/box/init_test.tl
  cosmic/quicksand/box/run_test.tl` ends `test: PASS (2 files)` — the two
  lazy requires still resolve through their guards.
- `o/bin/cosmic --docs cosmic.fs` prints the module's reference — the
  guarded doc-index load still serves.
- `git diff origin/main -- _build/public_surface_baseline.tl` is empty.
- `git diff --stat origin/main...HEAD` names exactly ten files: the nine
  sources above and `_build/casts_baseline.tl`.

## Enablement
none needed. The mechanism is `is` narrowing over `any`, stated in
AGENTS.md and demonstrated end to end by PR #1382 (`cosmic/init.tl`'s
`info is VersionInfo`, `_cli/main_handlers.tl`'s `ver is VersionInfo`);
the ratchet's regen command is printed by the gate that fails. The one
trap worth restating from #1382: the checker resolves `require("cosmic")`
from the RUNNING binary's embedded source before the working tree, so run
`bin/cosmic --make ci` (which converges) rather than a bare `--check
types` after editing a `cosmic/**` file.
