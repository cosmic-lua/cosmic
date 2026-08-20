## Evidence

2026-08-20 audit of `_fuzz/driver.tl` at main 0b2907b9, by reading
(not reproduced live). Three weaknesses in the crash path: (1)
driver.tl:268-269 reconstructs the crashing input by rerunning
`opts.gen` once in the parent, so a gen with process-global state
reports a wrong input — driver_test's own crash-test gen counts
calls and would report input "1" for a crash at iteration 5; the
test passes because it asserts only the iteration. (2)
`bisect_crash` (driver.tl:221-226) classifies a timed-out or
failed-to-start probe as "did not crash", steering the bisection
wrong — worst case reporting iteration=iters with a non-failing
input. (3) At deep-lane iteration counts the bisection probes
themselves run up to the same fixed 30s child wall clock, so probes
near the top of the range time out and hit (2).
