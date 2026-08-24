## Goal

G3 — the defining paths, measured. `cosmic.literal.parse` is on every
build's critical path: `--make fetch` reads every `*_pin.tl` with it,
`_make/patch.tl` reads the carried tl patch, and `_tool/floor.tl`
reads every committed ratchet floor (`_tool/floor.tl:39`,
`literal.parse_file`). No `_perf` scenario touches it, so a regression
in either reader — or the size of an improvement in one — is invisible
to the compare gate. This slice builds the instrument. It does not
optimize anything.

## Evidence

Measured 2026-08-24 on `main` at `5ef13f40`:

```
$ ls _perf/bench/*_bench.tl | wc -l
17
$ ls _perf/bench/ | grep -c literal
0
$ grep -n 'the 17 bench sources' _perf/perf_test.tl
11:-- `reads: _perf/bench` above puts the 17 bench sources into this test's
$ wc -l _perf/bench/format_bench.tl _perf/bench/json_bench.tl
  95 _perf/bench/format_bench.tl
 134 _perf/bench/json_bench.tl
$ wc -c 3p/cosmos/cosmos_pin.tl
276 3p/cosmos/cosmos_pin.tl
$ wc -l .cosmic-coverage; wc -c .cosmic-coverage
251 .cosmic-coverage
16054 .cosmic-coverage
```

Those two sizes are the two shapes the reader actually meets: a pin is
a few hundred bytes of nested table, and the coverage floor is 251
rows of `{covered = N, total = N}` — the largest literal this
toolchain reads, once per `--make coverage`.

**Discovery is automatic and needs no registration.** `_perf/run.tl`
globs `_perf/bench/*_bench.tl` (`discover_benches`, `:182-184`) and
`_perf/perf_test.tl` derives its module list the same way
(`discover_modules`, `:25-33`), so a new `*_bench.tl` is picked up by
both. The only hand-maintained number is the `17` in that test's
header comment.

**The two runner commands, run verbatim on `5ef13f40`** against an
existing module, so the Acceptance below quotes real output rather
than a guessed shape:

```
$ bin/cosmic --make run _perf/run.tl _perf.bench.time_bench --out o/perf/probe.json
time_format_date       509958 x  327.6 ns/op  ± 11.9%  cpu/wall 1.00  alloc 0.00 KB
time_format_iso8601    385325 x  468.2 ns/op  ±  6.9%  cpu/wall 1.00  alloc 0.00 KB
wrote o/perf/probe.json

$ bin/cosmic --make run _perf/gate.tl selfcheck o/perf/a.json o/perf/b.json --only time_
...
perf-selfcheck: nothing exceeded the bar — the machine is quiet at this threshold
(exit 0)
```

`selfcheck` WRITES both files it names — measuring twice is its job —
so both paths are outputs under `o/`, never committed.

## Change

Two files.

**1. `_perf/bench/literal_bench.tl`** (new) — a bench module in the
shape of `_perf/bench/format_bench.tl`: a module header saying what it
measures and why, inputs built once at load, a `scenarios()` returning
`{pt.Scenario}`, an empty `cleanup()`, and a `pt.BenchModule` returned
at the end.

Build two values in memory, deterministically, at module load:

- `PIN`, a table with the shape and rough size of a `*_pin.tl`: a
  `format`/`url`/`version`/`strip_components` set plus a nested
  `platforms` table of a few entries with `sha` strings. Aim for the
  few-hundred-byte range `3p/cosmos/cosmos_pin.tl` sits in.
- `FLOOR`, a table of 251 keys — `"path/to/file" .. i .. ".tl"` — each
  mapping to `{covered = <int>, total = <int>}`, the shape
  `.cosmic-coverage` carries at the size it carries it.

Beside each, its formatted source, produced once at load with
`literal.format` (the pin layout), so the parse scenarios time parsing
and not formatting.

Four scenarios, named exactly:

- `literal_parse_pin` — `literal.parse(PIN_SOURCE)`
- `literal_parse_floor` — `literal.parse(FLOOR_SOURCE)`
- `literal_format_pin` — `literal.format(PIN)`
- `literal_format_floor` — `literal.format(FLOOR)`

Every scenario defines `check` — the harness requires one, and a
missing one fails `_perf/perf_test.tl`. Make each check discriminate a
faster-but-wrong implementation rather than merely testing for
non-nil:

- a parse check narrows the result to `{string: any}`, then asserts a
  known scalar reached it (the pin's `version` string; a named floor
  row's `covered`) AND that the table has the expected number of
  top-level keys, counted with `pairs`. A reader that dropped entries
  would be faster and would fail here.
- a format check narrows the result to a string, parses it back with
  `literal.parse`, and asserts the round trip equals the value it was
  given on the same two probes plus the key count. A writer that
  skipped entries would be faster and would fail here.

Follow the repo's error shape: a check returns `boolean, string`, and
its failure message names the scenario and what it saw.

**2. `_perf/perf_test.tl`** — in the header comment at `:11`, change
`the 17 bench sources` to `the 18 bench sources`. That is the whole
edit to this file; the module list itself is derived and needs none.

## Non-goals

- **Do not optimize either reader or writer.** `cosmic/literal.tl`,
  `cosmic/_literal_lex.tl` and `cosmic/_literal_format.tl` are not
  edited by this item. It builds the instrument; a hypothesis it
  later supports is a different item.
- **Do not gate anything on these numbers.** `--make ci` does not run
  `_perf` and must not start; the compare gate stays the manual loop
  the `optimize` skill describes.
- **Do not pass `literal.parse`'s `engine` option, if the tree has
  one.** (Board item `3IKSjS8N`, PR #1362, adds one.) The scenario
  measures what an ordinary caller gets from the default path.
  Measuring a specific implementation is a different scenario and a
  different item.
- **Do not read a committed file at bench time.** Every sibling
  scenario builds its input in memory, and a scenario that read
  `3p/cosmos/cosmos_pin.tl` or `.cosmic-coverage` would silently
  re-measure whenever those files changed.
- **Do not change the harness or the runner** — `_perf/harness.tl`,
  `_perf/run.tl`, `_perf/gate.tl`, `_perf/compare.tl`,
  `_perf/stats.tl`, `_perf/perf_types.tl` are all untouched, and so
  is `_perf/perf_test.tl` beyond the one-word comment fix.
- **Do not commit `o/perf/*.json`**, and do not add a baseline file.

## Acceptance

Every command runs verbatim from the repo root and writes no committed
file.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _perf/perf_test.tl` passes — it discovers
  the new module and runs all four scenarios end to end with their
  checks.
- `bin/cosmic --make run _perf/run.tl _perf.bench.literal_bench --out
  o/perf/literal.json` ends `wrote o/perf/literal.json` and prints one
  `ns/op` line per scenario.
- `grep -c literal_parse_pin o/perf/literal.json` is 1, and the same
  for `literal_parse_floor`, `literal_format_pin`,
  `literal_format_floor` (all 0 before this change, when the file does
  not exist).
- `bin/cosmic --make run _perf/gate.tl selfcheck o/perf/a.json
  o/perf/b.json --only literal_` ends `perf-selfcheck: nothing
  exceeded the bar — the machine is quiet at this threshold` and exits
  0. A scenario that cannot beat its own A/A noise floor is not an
  instrument; if one flags here, shrink its per-op work (fewer keys,
  smaller input) until it is quiet, and say in the PR which one and by
  how much.
- `ls _perf/bench/*_bench.tl | wc -l` is 18 (17 at `5ef13f40`).
- `grep -c 'the 18 bench sources' _perf/perf_test.tl` is 1 and
  `grep -c 'the 17 bench sources' _perf/perf_test.tl` is 0 (0 and 1 at
  `5ef13f40`).
- `wc -l _perf/bench/literal_bench.tl` is ≤ 160 (95 and 134 are the
  two siblings this is shaped after; the cap is 500 and this bound is
  the slice's own).
- `git status --porcelain o/` prints nothing that is tracked — the
  results files above live under `o/`, which is not committed.

## Enablement

none needed. Both runner commands above were run verbatim and their
verdict lines are quoted rather than guessed; discovery is automatic
in both the runner and the smoke test, with the one hand-maintained
number named by line; the two input shapes are measured from the files
they imitate; and `_perf/bench/format_bench.tl` is a 95-line worked
example of exactly this module shape, including a check written to
fail a faster-but-wrong implementation.

`blocked_by` is empty and deliberately so. `3IKSjS8N` (PR #1362, the C
reader behind `parse`) touches no file this slice touches, and either
landing order works: land first and this scenario's first baseline
records the C reader, land second and the compare gate shows the
adoption's win, which is the better outcome and not worth serializing
for.
