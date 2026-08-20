## Evidence

2026-08-20 audit, reproduced on a local build at main 0b2907b9.
`_fuzz/driver.tl:48` sets `DEFAULT_TIMEOUT_MS = 30000`, applied at
driver.tl:256-257 to an isolated child's ENTIRE run of `iters`
iterations — sized for the 256-iteration default, while
`.github/workflows/fuzz.yml` runs the deep lane at `FUZZ_ITERS=50000`.
Measured: `tar_fuzz_test.tl` at 2000 iters is ~2s/property; at 50000
`tar_mutation_totality` is killed at exactly 30s and reported
`seed=20260820 iteration=50000 input(base64)= draws=0: hung: exceeded
30000ms` — a red lane with an EMPTY input, indistinguishable from a
real hang. `compress_fuzz_test.tl` fails the same way (30.4s); sse
measured 24.7s locally, a flake on a slower CI container. The 09:00
UTC cron of 2026-08-20 ran before child 5 (#1294) merged at 12:39 UTC,
so the next cron is the first exposed run. Also contradicts
driver.tl:44-47's claim that the wall clock is "only reached when the
VM instruction hook cannot arm … or the hang is inside a single C
call" — at deep-lane depth it is the binding constraint in normal
operation. Fix shape: scale the child timeout with the iteration
count (or set it per-lane in fuzz.yml), keeping a floor for the
default depth.
