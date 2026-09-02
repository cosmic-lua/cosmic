## Goal

G3 — an honest type layer. `_perf/bench/*_bench.tl` carries 11 census
rows that no sweep item covers: `_bench.tl` is not `_benchmark.tl`,
so neither #1579 (the tooling sweep) nor 3IQfJ1tn (the `cosmic/**`
sweep) reaches them, and #1578 (guard the latent nils in `_perf`)
predates the #1588 dedupe that introduced the helpers behind them.

## Evidence

Census Method re-run 2026-09-02 at `5a36e7c9`; the whole
non-`cosmic/**` remainder, all `in assignment`:

```text
_perf/bench/download_bench.tl:123  server_pid, listener = server.cleanup(server_pid, listener)  (2 rows)
_perf/bench/http_bench.tl:163      same shape  (2 rows)
_perf/bench/stream_bench.tl:127    same shape  (2 rows)
_perf/bench/embed_bench.tl:174          tmpdir = binary.cleanup(tmpdir)
_perf/bench/embed_startup_bench.tl:140  tmpdir = binary.cleanup(tmpdir)
_perf/bench/fs_bench.tl:205             tmpdir = binary.cleanup(tmpdir)
_perf/bench/startup_bench.tl:136        tmpdir = binary.cleanup(tmpdir)
_perf/bench/tar_bench.tl:147            tmpdir = binary.cleanup(tmpdir)
```

Shared helpers returning `T | nil` assigned back into non-nil module
locals. Re-measure at pull time with the Method's recipe recorded in
3IQfJ1tn's `## Enablement`.

## Change

Widen the receiving locals to `T | nil` (they are cleared on purpose)
or have the helpers return the cleared value's type honestly — pick
the shape the helper's callers already assume, one convention across
the eight files. `_perf/bench/*_bench.tl` and the two helpers only.

## Non-goals

- No scenario or check change; the harness's numbers are untouched.
- No file outside `_perf/`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan reports **0** rows under `_perf/`.
