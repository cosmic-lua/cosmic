## Goal

The release lane's next run survives its compare step. #1415 fixed
run.tl's version_info skew, but the same class has a second instance:
`_perf/bench/literal_bench.tl:140` calls the two-argument
`literal.format(FLOOR, {layout = "compact"})` (API added 2026-08-26,
#1400/#1403), and release.yml's compare step runs the bench modules
bare under the PREVIOUS release binary (2026-08-23), whose embedded
cosmic.literal predates FormatOptions — the module dies at load-time
type check and the compare step crashes before measuring, exactly as
run.tl did on 2026-08-26.

## Evidence

Reproduced 2026-08-27 against origin/main `ef963bab` with the actual
previous release asset:

- `<2026-08-23 cosmic-lua> _perf/run.tl --only literal_format_floor
  ... _perf.bench.literal_bench` → `error loading module
  '_perf.bench.literal_bench' from './_perf/bench/literal_bench.tl':
  140:31: wrong number of arguments (given 2, expects at most 1)` —
  bare mode loads the TREE bench file against the embedded stdlib.
- The full-tree sweep (`--check types` of every non-test `_perf/**`
  file under the prev binary) finds exactly one other skew,
  `_perf/gate.tl:77` (`compare.triage_many`, D31/#1419) — INERT: the
  workflow only ever runs gate.tl tree-resolved via `--make run`.
- The runtime hazard beyond the type error: Lua ignores extra
  arguments, so a merely-tolerant call under the old binary would
  silently measure the PIN layout under the compact scenario's name.
- Registration asymmetry is safe: a scenario present in current and
  absent in base reads as `new`, which the gate allows (`disappeared`
  is the failing direction).

## Change

`_perf/bench/literal_bench.tl` only:

1. A map-view reference `format_any` (casts justified, #1415's
   pattern) typed `function(any, any?): any`, used by the compact
   scenario's `fn` and by a `supports_compact()` probe: format a tiny
   probe table both ways; compact is supported iff the outputs
   differ (the old format ignores the opts and produces the pin
   layout twice).
2. `scenarios()` builds the list without the compact scenario and
   inserts it at its original position (3rd, keeping the
   floor-first heap ordering the header explains) only when
   `supports_compact()` is true.
3. The header comment gains the constraint (bare under older
   binaries; silent-pin hazard; register-on-support).

## Non-goals

- No gate.tl change (inert), no scenario weakening or rename, no
  check() change — the compact scenario is byte-identical when it
  runs.
- The class guard (type-check `_perf/**` under the previous release
  in CI) is its own filed item, not this fix.

## Acceptance

- Reproduction reversed: the prev release binary runs
  `_perf/run.tl ... _perf.bench.literal_bench` to completion,
  registering the floor scenarios WITHOUT `literal_format_floor_compact`.
- Current binary still registers it:
  `o/bin/cosmic --make run _perf/run.tl --only compact ...` measures
  `literal_format_floor_compact`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `git diff --name-only origin/main` lists exactly
  `_perf/bench/literal_bench.tl`.

## Enablement

none needed. The tolerant-view pattern is #1415's, landed; the
previous release asset is downloaded and the reproduction command
above is the test.
