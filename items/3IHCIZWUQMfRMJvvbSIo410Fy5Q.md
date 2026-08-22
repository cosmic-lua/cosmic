Imported from whilp/cosmic#1311.

## Goal

G6 — every release measures the defining paths and answers for them. The
release perf gate (#1261) is G6's teeth, and it is currently preventing the
release from existing at all: a gate that blocks the artifact indefinitely,
with nobody notified and nothing on the board, serves neither G6 nor the
anchor promise. The instrument must be able to say "regression" or "noise"
and someone must be on the hook for the answer the day it goes red.

## Evidence

#1261 (2026-08-17) made the release perf compare blocking. Every scheduled
release since has failed at "compare against the previous release", all
against the same stored baseline `2026-08-17-f421fa1`:

    08-18 run 32108462657: 22/43 regression -> FAIL   (first run after the gate armed)
    08-19, 08-20, 08-21:   FAIL at the same step
    08-22 run 32557687549: 18/43 regression -> FAIL

No cosmic release has published in 5 days while ~25 PRs landed on main; the
Landlock ABI 4-9 pin bumps (#1301, #1303) have never shipped in a release.
Nothing tracked this before whilp/cosmic#1311 (filed 2026-08-22): the fuzz
lane's doctrine says a red scheduled run "fails loudly", but a scheduled
failure notifies nobody and creates no item — loud is not noticed.

The 08-22 flagged profile is broad and skewed toward spawn/fs scenarios
(fs_stat_tree +99%, fs_walk_tree +92%, tar_extract_tree +69%,
http_fetch_get +57%, child_spawn_true +42%, startup_run_lua +39%) while
pure-CPU scenarios (json, hash, re, time) sit within noise. Two hypotheses,
undecided:

1. a real regression from the 08-17 -> 08-18 merge window (the gate failed
   on its first day, one day past baseline);
2. measurement design: the same-day A/A selfcheck that sets the ±10% noise
   floors cannot see day-to-day runner variance, so a stored cross-day
   baseline may be structurally unbeatable. #1307 fixed the retry
   clobbering CUR; the retry has saved none of the five runs.

## Direction

The deciding experiment is one interleaved A/B on a single machine between
the 2026-08-17-f421fa1 release binary and a current-main build (the
optimize skill's measurement discipline). If it reproduces: a perf item.
If not: the gate needs the baseline binary re-measured in the same run as
the candidate (interleaved), not compared against another day's stored
numbers, before it can stay blocking. Likely children on refinement:
the deciding A/B; the same-run baseline re-measure; and a mechanical
capture path for any scheduled lane's red run (release, fuzz, docs), so
the next five red days cost one, not five.

## Findings (measured 2026-08-22, the Direction's deciding A/B)

Interleaved A/B on one machine (4-core x86_64 container), A = the
2026-08-17-f421fa1 release binary (sha d00aef83, cosmos 2026.08.15),
B = a same-tree build of main at ff09b575 (cosmos 2026.08.21). Full
suite twice each, alternating (A1 B1 A2 B2), then 6 more alternating
`--only tar_extract` rounds. Repro:

    ./cosmic-lua _perf/run.tl --out A.json   # release asset
    o/bin/cosmic _perf/run.tl --out B.json   # alternate, repeat

1. **42 of 43 scenarios: no regression.** B within ±8% of A, most
   within ±4%, several faster. Every fs/spawn/startup scenario CI
   flagged at +39..99% measures +0.2%..+1.6% here.
2. **The gate's flags are runner variance, structurally.** The same A
   binary drifts -39%..+162% between this machine and its own CI run
   (child_spawn +162%, startup +33%, fs_stat -29%) — per-scenario,
   in both directions. And the baseline's own release notes show
   f421fa1 FAILED its compare against a3cd318 measured 11h earlier
   the same day, +30..70% on nearly every scenario including pure
   CPU (sha256_small +68.6%). Cross-run comparison has never passed:
   the same-run A/A selfcheck floor (±10%) cannot see between-run
   variance, so the gate as designed cannot stay green.
3. **One real regression: tar_extract_tree.** B slower in 5 of 5
   interleaved pairings: A 7.29-7.62 ms (tight), B 7.84-10.17 ms
   (~+8% floor, spikes to +37%; CI saw +69%, same direction). No
   cosmic-layer change touches tar since 08-17; the moving part is
   the cosmos pin, and the 08-21 cosmos releases are the FIRST to
   ship lua as MODE=rel — whilp/cosmopolitan#262's territory: the
   JCC-erratum per-link layout lottery, whose padding fix
   (-Wa,-mbranches-within-32B-boundaries) was PR'd 08-15 and never
   merged. Filed as its own capture.

## Consequences

- The gate fix (Direction item 2) is confirmed: the compare must
  measure the previous release binary interleaved in the same job
  (the baseline step already downloads release assets — measure the
  prev cosmic-lua beside the candidate instead of reading its
  stored perf.json), with the floor from that same-run pairing.
- Unblocking the release is now a policy call, not a mystery: a
  perf_gate:false dispatch re-baselines and ships (knowingly
  carrying tar +8%, captured), or the same-run gate fix lands first
  and judges honestly. Blocking all releases for 17 false flags and
  one +8% scenario is the current state; neither hypothesis needed
  the runner re-run the gate's own error text suggests.
