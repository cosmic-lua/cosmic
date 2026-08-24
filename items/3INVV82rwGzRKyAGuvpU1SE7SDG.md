`_perf/bench/` has no literal scenario, so `cosmic.literal.parse` —
which `--make fetch` uses to read every pin, `_make/patch.tl` to read
the carried tl patch, and `_tool/floor.tl` to read every committed
ratchet floor — is measured by nobody. Measured 2026-08-24 at
`a2937536`:

```
$ ls _perf/bench/ | grep -c literal
0
```

The gap became concrete refining `3IKSjS8N` (adopt the C literal
parser behind `literal.parse`). That slice's question 5 — how the win
is reported — was settled as "scouting numbers in the PR description,
not a gate", precisely because there is no scenario to gate on. So a
C parser adoption motivated by a 47-53x gap will land with its
improvement unratcheted, and any later regression in either reader is
invisible to the compare gate.

A slice here adds `_perf/bench/literal_bench.tl` in the shape of the
sibling codec scenarios (`json_bench.tl`, `format_bench.tl`), with
per-scenario functional checks, covering parse and format over a
representative pin-sized input. The `optimize` skill's loop is what
settles the scenario's shape and its noise floor.
