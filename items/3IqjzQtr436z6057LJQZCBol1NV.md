## Evidence

Decided by the goal owner in conversation, 2026-09-04: the release no
longer gates on the perf compare; the same measurement moves to a
scheduled daily lane that reports and never blocks anything.

Forces, measured. `release.yml`'s "compare against the previous
release" step has refused to publish on noise more often than on
regressions: five consecutive scheduled releases 2026-08-18..22 (the
step's own comment), three held 2026-08-24..26 (D31's context), and
the 09-03 run (`33746684991`, `re_match_log_line +1.5%` inside a
±10% band, counted as a regression because "no same-binary control
explains the gap"). D31, D34→D36 and D35 each bought the gate more
evidence and each record says plainly it lowers the false-red rate
without eliminating it. Meanwhile a red release lane holds the trust
root: `bin/cosmic.pin` cannot advance to a release that does not
exist, and today three cosmos pin bumps and their dependents wait on
exactly that («Xvox_XNCM» → `3IkMf7BY`, `3ImjB20O`, `3In3fTdC`). The
compare instrument itself is sound and stays; what changes is what a
red verdict is allowed to stop.

What the tree pins today (`grep -n` at `79aa8c16`):
- `.github/workflows/release.yml:13-17` — the `perf_gate` dispatch
  input; `:120-139` "measure the release"; `:141-201` "compare against
  the previous release"; `:240-247` the artifact list carrying
  `perf.json`, `selfcheck.json`, `compare.txt`; `:330-375` the
  `release` job copies and publishes those three and puts
  `compare.txt`'s verdict line first in the release notes.
- `_build/workflows_test.tl:345-392` — two ratchets over that step
  (`pipefail`/`exit "$rc"`/no `|| true`/SKIP path; `_perf/baserun.tl`
  and `--baseline-bin`), and `:127-343` the per-workflow container /
  digest / privileged / non-root-builder ratchets that any new
  workflow file inherits via `workflows()` (`fs.find` over
  `.github/workflows/*.yml`).
- `docs/goals.md:131-142` (G6: "enforced by the existing
  `perf-compare` gate", "ratchets per release") and `:173` (G9: "the
  perf history (G6's release-asset pattern)").
- Comments naming the release step: `_perf/baseline.tl:2-24`,
  `_perf/gate.tl:426`, `_perf/skew_test.tl:1-12`,
  `skills/optimize/SKILL.md:59`; `AGENTS.md:56-59` and `:399-403`
  list the lanes.
- Board tool: `o/board/_work/lanes.tl:29` `LANES = {"release.yml",
  "fuzz.yml", "docs.yml"}` — the new lane is not observed by `sync`
  until that list grows; that is a board-tool item, not this PR.

Schedule: release.yml fires `0 6 * * *`, fuzz.yml `0 9 * * *`. The
perf lane fires `0 3 * * *`, BEFORE the release, so its compare is
"today's main against the latest published release" — yesterday's
main — and never the near-A/A of a binary against its own commit
that an after-release slot would measure.

## Change

One PR on cosmic-lua/cosmic, `Board:` this item.

1. New `.github/workflows/perf.yml`, modelled line for line on
   `fuzz.yml` (same digest-pinned `buildpack-deps` container and
   `--privileged` options, same `prepare non-root builder` step, same
   `concurrency` shape, `permissions: contents: read`, `if: always()`
   artifact upload). Triggers: `schedule: '0 3 * * *'`,
   `workflow_dispatch` (no inputs), and `pull_request` on
   `.github/workflows/perf.yml` only, so the PR that adds it proves
   its plumbing. One job `perf`, `timeout-minutes: 60`, steps as
   `builder`: `bin/cosmic --make fetch`; `bin/cosmic --make build &&
   o/bin/cosmic --make build` (the measured binary is built by its own
   rules, as the release is); measure `_perf/run.tl` twice into
   `o/perf/perf.json` and `o/perf/selfcheck.json`; then the compare
   step, named `compare against the latest release`, carrying
   release.yml's current step body verbatim minus the `PERF_GATE`
   env and its `if [ "$PERF_GATE" = "true" ]` branch: `_perf/baseline.tl
   --asset cosmic-lua` → `_perf/baserun.tl` → `_perf/gate.tl compare
   … --baseline-bin`, under `bash -eo pipefail`, `perf-compare: SKIP`
   still succeeding, `exit "$rc"` on failure. The failure message
   says what a red run means now: nothing is blocked or unpublished;
   re-run to re-measure, a real regression reproduces and noise does
   not; work a reproduced one under `skills/optimize/SKILL.md`. Append
   `compare.txt`'s verdict line to `$GITHUB_STEP_SUMMARY`. Upload
   `o/perf/perf.json`, `selfcheck.json`, `compare.txt`,
   `baseline.txt`, `prev/perf.json` as artifact `perf-<YYYYMMDD>`.
   The lane IS allowed to go red on a real regression — that is its
   only signal — it just gates nothing.
2. `.github/workflows/release.yml`: delete the `perf_gate` input, the
   "measure the release" and "compare against the previous release"
   steps and their comments, the three perf paths in the `build` job's
   artifact list, and in the `release` job the `perf_src`/
   `selfcheck_src`/`compare_src` lookups, checks, copies and asset
   arguments; release notes become size-compare's and peers' verdict
   lines. The size measure/compare (G9) and the `peers` job are
   untouched. Rewrite the gate comment above `--make ci` only where it
   mentions perf.
3. `_build/workflows_test.tl`: repoint
   `test_the_release_perf_compare_propagates_its_verdict` and
   `test_the_release_baseline_runs_the_trees_perf` at
   `perf.yml`'s `compare against the latest release` step (rename
   them `..._perf_lane_...`), and add
   `test_the_release_does_not_gate_on_perf`: `release.yml`'s `build`
   job body contains neither `_perf/gate.tl` nor `_perf/run.tl` nor
   `perf_gate`. `UNCONTAINERISED` gains no entry: the perf job is
   containerised and the existing ratchets cover it.
4. `docs/decisions/d44-<slug>.md` per `skills/decide/SKILL.md`: the
   release publishes regardless of the perf compare; perf is a daily
   non-blocking lane against the latest release. Rejected: keep the
   gate with a wider bar or an exemption list (D31's own rejected
   list, and the failure mode is unchanged); `perf_gate: false` by
   default (a gate nobody enables is a report with a misleading
   name); triggering the lane from the release (`workflow_run`) to
   compare release-to-release (needs a second-newest-release picker
   in `baseline.tl`, and slots the measurement after the artifact it
   would have informed). Consequences: a regression ships and is
   found the next morning; the compare's D31/D34/D35/D36 rules are
   unchanged and now govern `perf.yml`; releases stop carrying
   `perf.json`/`selfcheck.json`/`compare.txt` (the history is the
   lane's run artifacts, 90-day retention); revisit if a shipped
   regression costs more than the held releases did. Run
   `bin/cosmic _docs/derive.tl` for the index.
5. Prose that states the rule in place: `docs/goals.md` G6 —
   "enforced by the existing `perf-compare` gate" becomes "reported by
   the daily perf lane (`perf.yml`), main against the latest release,
   never a release gate", "measured by: the perf suite's ratchets per
   release" becomes per day; G9 `:173` drops "(G6's release-asset
   pattern)" in favour of naming the size report's own release-asset
   pattern. `AGENTS.md:56-59` gains a `perf.yml` line and `:399-403`
   a `perf.yml` bullet (cron, what it compares, that it never blocks).
   Comments: `_perf/baseline.tl:2-24` ("the perf gate" → "the perf
   lane", "fail a release" → "fail the lane"), `_perf/gate.tl:426` and
   `_perf/skew_test.tl:1-12` (`release.yml` → `perf.yml`, "release
   lane" → "perf lane"), `skills/optimize/SKILL.md:59`.

Walls: `_perf/gate.tl`, `_perf/compare.tl`, `_perf/tiebreak.tl`,
`_perf/baseline.tl`'s behaviour and every verdict-line format are
frozen — this PR moves the caller, not the instrument. `_perf/run.tl`'s
JSON format is frozen. No change to `pr.yml`, `fuzz.yml`, `docs.yml`.

## Non-goals

- Not the `includeIf`/`origin/board` fix in `release.yml` — «Acp1_MOgO»,
  a separate PR on the same file; whichever lands second rebases.
- Not adding `perf.yml` to gitboard's `LANES` — a board-tool item.
- Not resolving `c5wU_p1n9` (the `re_match_log_line` question): it
  stops holding the release and stays a perf item.
- Not `3IHHKCyzBe8` (perf.json's role as a release asset): this PR
  dissolves it; it is ended when this lands.
