The outcome, its measurement, and its win condition live in docs/goals.md.

## Decomposition audit, 2026-08-19 (owner confirmed the band-7 ranking; measured at bff1007)

The empty subtree overstated the gap — most of the win condition is
BUILT and gating:

- **Release-over-release ratchet: holds.** `release.yml` measures every
  release with the `_perf` harness (plus an A/A self-check), fetches
  the previous release's `perf.json` (`_perf/baseline.tl`), and a
  `perf-compare: FAIL` blocks publishing — the release-asset chain IS
  the perf history. `perf_gate: false` on dispatch is the one
  legitimate re-baseline door.
- **Peer table: published every release.** The `peers` job runs
  `_perf/peers/run.tl` and ships `peers.json`/`peers.md` as release
  assets, with the table's last line in the release notes (PR #1264).
- **Defining-path coverage:** startup (`startup_bench`,
  `embed_startup_bench`, and the peer table), `--check types` latency
  (`teal_bench`: `cosmic.teal.check` over a representative module,
  hermetic), embed cycle (`embed_bench`) — all inside the gated suite.

Three real gaps, in intended order (file as slots open; every column
is at its WIP limit today, which is why this plan lives here):

1. **Trend view over the release chain.** The gate is pairwise
   non-regression; "trending down across releases" is asserted by
   nobody. A slice: read the chain of release `perf.json` assets
   (`_perf/baseline.tl` already fetches one; the walk generalizes it),
   render per-defining-path trend lines into the release notes or the
   docs branch. Observational output, never a gate.
2. **Peer table v2 — the checker path.** The table covers startup
   only; the win condition wants the defining paths. The refinement
   must settle the comparable-workload question (what is "the same
   metric" for `--check types` against CPython/Node/Go's ecosystems —
   likely tsc/mypy on size-matched sources) before it is sliceable;
   that settlement is the next refine rung, not implementation.
3. **Cycles-per-task ratchet — blocked on G1.** The fourth defining
   path is measured by the agent-eval instrument, and G1 has no live
   work. G6 cannot finish without a G1 decomposition first; intake
   should treat G1's emptiness as the blocking gap, not file a G6
   placeholder.
