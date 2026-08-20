## Evidence

2026-08-20 audit, reproduced on a local build at main 0b2907b9.
`_fuzz/driver.tl:156-170` calls `disarm_budget()` BEFORE
`shrink.shrink(...)`, and `_fuzz/shrink.tl:41` pcalls `prop.check` on
each candidate with no hook armed and no per-call time bound
(`MAX_SHRINK_ATTEMPTS` bounds call COUNT only). After a `budget=<n>
exceeded` failure, shrink re-invokes the same non-terminating check:
reproduced with a gen that draws bytes and a `while true do end`
check under `budget=100000` — `run_unisolated` never returns, and
under `run()` isolation the child burns to the 30s wall clock and
reports `hung: exceeded 30000ms` with an empty input, exactly the
attribution loss the budget (#1291) was landed to prevent. This also
bites ordinary failures whenever a shrink CANDIDATE makes check loop.
`driver_test.tl`'s two looping-budget tests (lines 245-314) pass only
by construction — their gens draw zero values, so shrink sees an
empty sequence and never calls check. Fix shape: arm the budget
around shrink's candidate checks (re-using the driver's hook), and
give the looping-budget tests a gen that draws.
