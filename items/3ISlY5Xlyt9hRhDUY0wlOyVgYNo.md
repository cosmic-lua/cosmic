`json_decode_large` cannot be judged by one suite pass: it varies by
more than the gate's bar against the SAME binary, so `release.yml`'s
perf gate can hold a release for a scenario nothing changed.

Measured 2026-08-26 under cosmic board item `3ISWHyP7`, on a 4-core
container.

**Against itself, in suite context, it clears the bar.**
`o/bin/cosmic --make run _perf/gate.tl selfcheck o/perf/a.json
o/perf/b.json` at `main` `ec794d44` →
`perf-selfcheck: the scenarios flagged above vary by more than the bar
on noise alone`, `48 scenarios: 7 regression, 1 faster, 40 ok`, with
`json_decode_large` 1.21 ms -> 1.36 ms **+12.6%** — one binary, one
tree, no change. Six others did the same: `tar_extract_tree` +48.5%,
`fs_walk_tree` +21.1%, `teal_check_module` +19.2%,
`literal_format_pin` +17.6%, `literal_parse_pin` +11.9%,
`format_module_source` +10.2%.

**In isolation it is quiet within a run and drifts between runs.**
`selfcheck … --only json_decode_large` → +0.5% (±2.9%) and -3.1%, both
`nothing exceeded the bar` — but the two calls' medians were 1.14 ms
and 1.27 ms, about 11% apart.

**The pin is not the cause.** The A/B in `3ISWHyP7` (cosmic held at
`ea71d799^`, only `3p/cosmos/cosmos_pin.tl` varied, three isolated
readings per side) gave `07fc94a1c` 1.26 / 1.67 / 1.19 ms (± 16.0 /
15.4 / 15.9%) against `354c17e08` 1.11 / 1.24 / 1.24 ms (± 8.0 / 7.5 /
7.2%). The newer cosmos is if anything faster and markedly more
stable. The release lane's +11.6% flag for this scenario is machine
variance, not code.

So the gate has a real hole: it enforces a fixed 10% bar plus a single
A/A triage pass, and `_perf/compare.tl`'s triage only downgrades a
regression when that one immediate self-check happens to catch the
scenario misbehaving. A scenario that is quiet in the triage pass and
noisy an hour later reads as a regression and blocks the release, which
is what happened on 2026-08-24.

The fix is a decision, not a number nudged upward. Write it under
`skills/decide` (D-record) before touching `_perf/`, and weigh at least:

- **Repeat rather than widen.** For a flagged scenario, re-measure it
  in isolation N times per side and require consistent direction —
  `measurement.md`'s existing tie-breaker, promoted from advice to
  something the gate does.
- **A per-scenario noise profile**, measured and committed the way the
  coverage floor is, so the bar is each scenario's own demonstrated
  variance instead of one global 10%.
- **What NOT to do**: raise `--threshold`, or add these scenarios to
  the gate's noise-excused set. `codec_base64_roundtrip_64k` came out
  of the same A/B as a REAL, reproducible +7.8% — so any change that
  would have excused `json_decode_large` must still fail on base64, or
  it has broken the gate rather than fixed it.

Also worth deciding: the other six scenarios above fail their own A/A
on a 4-core box. Whether the release runner is quiet enough for them,
and whether the gate should refuse to render a verdict at all when its
own self-check is this loud, belongs in the same record.
