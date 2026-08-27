## Evidence

3IUBNQZZ makes the perf report name the BINARY behind each side
(`binaries: base <sha12>  current <sha12>  (same|differ|unverifiable)`).
That closes half the chaining hazard 3IU0GxoA established, and leaves
the other half open: the effect 3IU0GxoA measured is indexed by
SESSION, not by binary. Cosmic `d8492168eace…` — the same bytes,
`sha256sum`-verified three times — read median 191.31 µs in one
session and 144.29 µs in another with disjoint ranges (+32.6%), so two
reports whose `binaries:` line says `(same)` can still be
uncomparable, and the header as specified would say nothing about it.

The data is already on disk and already ignored. `_perf/run.tl`'s
`collect_meta` writes `timestamp = time.now()` into every results
file, and `_perf/compare.tl`'s `RESULTS_SPEC` does not name
`timestamp`, so `shape.into` DROPS it before any comparison code could
read it (measured 2026-08-27 at `origin/main` `54aa87df`:
`git show origin/main:_perf/compare.tl | grep -n 'timestamp'` → no
matches; `git show origin/main:_perf/run.tl | grep -n 'timestamp ='` →
one match in `collect_meta`).

The candidate change is small: name `timestamp` in `RESULTS_SPEC`, and
extend 3IUBNQZZ's header line with each side's
`time.format_iso8601(math.floor(ts))` and the signed gap between them,
so a reader sees at a glance whether the two sides were measured
minutes or a day apart. Wait for 3IUBNQZZ to land before refining
this — it edits the same header line, and the two must not be cut in
parallel.

## The wall this inherits

Informational only. 3IU0GxoA's "What this does NOT license" binds: the
20-33% cross-session spread is NOT a noise budget for the release lane,
which measures baseline and candidate in the SAME job on the SAME
runner. A gap field may never become a refusal, a warning that changes
an exit code, or a reason to widen a bar — `DEFAULT_THRESHOLD_PCT`
stays `10.0` and `TRIAGE_K` stays `2.0`.
