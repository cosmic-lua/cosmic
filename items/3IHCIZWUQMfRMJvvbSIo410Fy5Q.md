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
