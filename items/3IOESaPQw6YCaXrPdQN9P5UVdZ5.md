The eval instrument's machinery exists — `_eval/` carries suite,
tasks, stage, journal, score, checks — but nothing runs it on a
cadence: no workflow references it (measured 2026-08-25: `grep -rn
eval .github/workflows/*.yml` matches nothing), so there is no
tracked history, no per-release run, and no peer baselines. G1's win
condition is exactly that standing, and two outcomes read this
instrument for their own win conditions (G6's cycles-per-task
ratchet, G4's "agents adopt it unprompted"), so while the instrument
is down those conditions are unmeasurable. The shape: a scheduled
workflow running the suite against the release artifact, history as
release assets alongside the perf history (the established
release-asset pattern), and the suite's one hard gate — zero silent
bugs across the suite — enforced on every run. The `agent-eval`
skill holds the round mechanics.
