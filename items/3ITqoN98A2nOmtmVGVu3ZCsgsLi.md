## Goal

G6 — the defining paths, ratcheted: the compare gate's escalation can
measure BOTH binaries in one machine window, so a baseline measured in
an earlier (or even ten-minute-old) window stops producing a FAIL no
triage can clear. Unblocks 3ITnbooy (the cosmos pin bump), whose
rework hit exactly this twice.

## Change

All in `_perf/gate.tl` (319 lines today, `wc -l` — 181 of headroom)
and `_perf/gate_test.tl` (396 lines — 104 of headroom; if the new
tests overflow it, split a `gate_ab_test.tl` beside it rather than
squeezing):

1. `compare` mode gains an optional `--baseline-bin PATH` argument
   (parsed beside `--threshold` in `main`). Absent → behavior is
   byte-identical to today.
2. `GateOptions` gains `baseline_bin: string` (optional field),
   `measure_only: function(out: string, only: string): integer` (the
   current binary, in-process — `run.main` with `--out`, the caller's
   runargs, then `--only SUB`), and `measure_bin: function(bin:
   string, out: string, only: string): integer` (a child process:
   `cosmic.child` runs `{bin, "_perf/run.tl", "--out", out, "--only",
   only}` — the release compare step's own bare-load shape, guarded
   by `_perf/skew_test.tl`). `main` wires both; tests inject fakes.
3. A final escalation stage in `gate_inner`, after `triage_many`
   still fails and only when `baseline_bin` is set: collect the
   still-flagged rows whose verdict is exactly `"regression"` (the
   deltas are needed, so `compare_once` also returns its `{pt.Delta}`
   list; error/missing/malformed/baseline-error rows are NOT
   clearable by A/B and keep failing). For each such row, run 3
   interleaved pairs — `measure_bin(baseline_bin, ab-base-i, row)`
   then `measure_only(ab-cur-i, row)`, i = 1..3, paths via the
   `retry_path` convention beside `current` — and clear the row when
   `|delta at medians| <= max(threshold, max spread_pct across the
   six passes for that row)`, where delta-at-medians uses the median
   of the 3 base `wall_ns` against the median of the 3 cur `wall_ns`
   (each pass's `wall_ns` is already that run's median). Every
   flagged row cleared and no other failure kind present → exit 0;
   anything else → 1, naming the rows the A/B confirmed. Print one
   line per row with the six numbers so the PR/lane log carries the
   evidence.
4. Identity guards, same rule as the existing stages: each ab-base
   file must name the SAME binary as none other than itself — assert
   the pair (ab-base-i, baseline) is NOT same-binary-refused against
   the current side by checking (ab-cur-i, retry) same=true and
   (ab-base-i, ab-cur-i) same=false; a violation is a wiring error
   and exits 1 with the refusal.

Rationale recorded from the capture's two instances: current-side
controls cannot clear drift that lives in the baseline file
(fs_walk_tree +25.6% vs interleaved +2.3%; literal_parse_pin +21.6%
vs overlapping ranges), and baseline AGE alone is not the fix — ten
minutes was enough — so the stamp/warn option is rejected and the
interleaved instrument is the mechanism.

## Non-goals

No release.yml change: wiring `--baseline-bin` into the release
compare step is its own follow-up once the flag proves out locally
(file it at review if this lands). No change to `triage_many`,
`TRIAGE_K`, or the noise-bar formula of the existing stages. No new
module unless the test cap forces the test split named above. Frozen:
the `perf-compare: PASS|FAIL` verdict line format, and the results
JSON shape (the A/B stage reads standard `run.tl` outputs).

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _perf/gate_test.tl` passes, including new
  tests whose names contain `ab_`: a regression cleared by the
  interleaved medians exits 0; one confirmed by them exits 1; with no
  `baseline_bin` the flagged path is byte-identical to today (the
  existing tests keep passing unmodified).

## Enablement

none needed — `run.tl --only` exists, `cosmic.child` exists, the
skew guard for bare-load of `_perf/**` under an old binary landed as
3ITdgu6f, and the test seam (injected measure) is established.
