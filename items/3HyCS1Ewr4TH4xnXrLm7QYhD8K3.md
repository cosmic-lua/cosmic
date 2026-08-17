Imported from whilp/cosmic#1122.

## Goal

G6 — the defining paths, ratcheted, via epic #1120.

## Change

Make the release's existing perf compare refuse a regressing release. The measurement
and publication half landed with #1121: `release.yml` measures the release binary
(release.yml:120-127), fetches the previous release's `perf.json`
(`_perf/baseline.tl`), runs `_perf/gate.tl compare`, and publishes `perf.json` +
`compare.txt` as release assets. The compare's verdict is currently thrown away twice
over: the gate's exit status reaches the step through `| tee o/perf/compare.txt`, and a
pipeline's status is `tee`'s, and then a trailing `exit 0` (release.yml:152) discards
whatever survives. Two files change; `_perf/**` does not.

The baseline exists now: release `2026-08-17-a3cd318` carries a `perf.json` asset (43
scenarios, none errored), and `_perf/baseline.tl` selects it by rule. The gate's noise
policy is `_perf/gate.tl`'s existing one, unchanged and unparameterised — the default
10% bar widened per scenario to the larger of the two runs' observed spread
(`_perf/compare.tl:97`), one automatic re-measure, then an A/A self-check on the same
runner in the same job that reclassifies a swing the binary reproduces against itself
as `noise` (`_perf/gate.tl:116-163`, `TRIAGE_K` at `_perf/compare.tl:26`). Because the
A/A control is measured on the release runner itself, no release-runner-specific margin
and no historical calibration is introduced.

**1. `.github/workflows/release.yml`**

- In `on.workflow_dispatch.inputs`, after `prerelease`, add:

  ```yaml
      perf_gate:
        description: 'Fail the release on a perf regression'
        required: false
        type: boolean
        default: true
  ```

- On the "compare against the previous release" step (release.yml:136-152), add to the
  step's existing `env:` block, beside `GH_TOKEN`:

  ```yaml
          PERF_GATE: ${{ github.event.inputs.perf_gate == 'false' && 'false' || 'true' }}
  ```

  A cron fire has no inputs, so `PERF_GATE` is `true` there: scheduled releases always
  gate, and only an explicit dispatch with the box cleared turns the gate off.

- Replace that step's `run:` block with exactly this, keeping the `runuser -u builder`
  + `env HOME=… PATH=…` pattern of its neighbours:

  ```yaml
        run: |
          set -ux
          rc=0
          runuser -u builder -- env HOME="$HOME" PATH="$PATH" GH_TOKEN="$GH_TOKEN" \
            bash -eo pipefail -c '
            o/bin/cosmic --make run _perf/baseline.tl --repo ${{ github.repository }} \
              --out o/perf/prev/perf.json | tee o/perf/baseline.txt
            if grep -q "^perf-baseline: SKIP" o/perf/baseline.txt; then
              echo "perf-compare: SKIP (no baseline: first measured release)" > o/perf/compare.txt
            else
              o/bin/cosmic --make run _perf/gate.tl compare \
                o/perf/prev/perf.json o/perf/perf.json o/perf/selfcheck.json \
                | tee o/perf/compare.txt
            fi' || rc=$?
          if [ "$rc" -ne 0 ]; then
            [ -f o/perf/compare.txt ] && cat o/perf/compare.txt >&2
            tail -n1 o/perf/baseline.txt >&2
            echo "perf gate: this release regressed against the previous one and was not published." >&2
            echo "  re-run the release workflow to re-measure: a real regression reproduces, noise does not." >&2
            echo "  if it reproduces, work it under skills/optimize/SKILL.md; never weaken a scenario or its check()." >&2
            echo "  after a deliberate scenario rename or removal, re-baseline by dispatching this workflow once with perf_gate: false." >&2
            if [ "$PERF_GATE" = "true" ]; then exit "$rc"; fi
            echo "perf gate: DISABLED by workflow input — regression reported, not enforced." >&2
          fi
  ```

  Three edits are load-bearing and each is required on its own: `bash -eo pipefail -c`
  (without `pipefail` the compare's status is `tee`'s and the gate stays decorative),
  the deletion of the trailing `exit 0` at release.yml:152, and `set -ux` rather than
  `set -eux` on the outer shell so `rc` can be captured. The `exit 0` at
  release.yml:187 belongs to the size step and stays.

- Replace the report-only paragraph of that step's comment (release.yml:129-135) with
  what the gate now means: a `perf-compare: FAIL` verdict fails the `build` job, so the
  `release` job (`needs: build`) never runs and a regressing release publishes no
  assets — which is the ratchet's point, because the baseline then stays the last
  release that passed. A `perf-baseline: FAIL` (network or API failure) fails the step
  too; the next cron fire retries. `perf-compare: SKIP (no baseline)` still succeeds.
  Record that `perf_gate: false` on a dispatch is the one way to publish a new baseline
  when the scenario set legitimately changed — `_perf/compare.tl:115-121` counts a
  scenario present in the baseline and missing from the current run as a failure, so a
  rename with the gate on would block every later release too.

**2. `_build/workflows_test.tl`** — the verdict can be re-swallowed by a one-token
edit, so ratchet it where the other workflow pins are ratcheted. Add a `step_body(path,
name): string` helper (scan from the line whose trimmed text is `- name: ` to the
next line at that same indentation, the same line-scanning technique `jobs_in` uses and
for the same reason: step names contain `-`) and one test,
`test_the_release_perf_compare_propagates_its_verdict`, over the body of
`.github/workflows/release.yml`'s "compare against the previous release" step,
asserting that it:

- contains `pipefail` — with a message saying that the compare's status arrives through
  `| tee` and a pipeline's status is `tee`'s;
- contains `exit "$rc"` — the step propagates the compare's exit code;
- contains no `|| true` and no `continue-on-error`;
- still contains `perf-compare: SKIP` — the bootstrap path stays a pass.

Measured headroom against the 500-line file cap, and the pre-change values of every
count the Acceptance greps:

```facts
$ wc -l < .github/workflows/release.yml
251
$ wc -l < _build/workflows_test.tl
278
$ grep -n 'exit 0' .github/workflows/release.yml
152:            exit 0'
187:            exit 0'
$ grep -c pipefail .github/workflows/release.yml
1
$ grep -c perf .github/workflows/pr.yml
1
$ grep -n 'DEFAULT_THRESHOLD_PCT = 10.0' _perf/compare.tl
18:local DEFAULT_THRESHOLD_PCT = 10.0
$ grep -n 'TRIAGE_K = 2.0' _perf/compare.tl
26:local TRIAGE_K = 2.0
$ grep -n 'perf-compare: FAIL' _perf/gate.tl
94:    print("perf-compare: FAIL")
$ ls _perf/bench | wc -l
17
```

## Non-goals

- **No changes under `_perf/`.** Not `gate.tl`, not `compare.tl`, not `baseline.tl`,
  not `run.tl`, not a scenario. No `--threshold` on the compare invocation and no new
  threshold constant: the bar is the one already in the tree, and inventing a
  release-specific number is the decision this slice deliberately does not make.
- **No scenario allowlist.** The gate covers every scenario the suite reports, which is
  what goals.md's "everything off the defining paths stays plain non-regression" asks
  for; do not add a defining-path filter, a per-scenario severity, or a skip list.
- **pr.yml is not touched** (its only perf mention today is the `!o/perf` artifact
  exclusion). G6's ratchet is per-release; per-PR measurement is not in this slice.
- **The size steps stay report-only** (release.yml:161-187, and `_build/size.tl:8-11`
  says so in its own words: G9 surfaces growth, never refuses it). Do not add
  `pipefail` or status propagation there, and do not touch `size.tl`.
- **The "measure the release" step (release.yml:120-127) keeps both harness runs** and
  its unguarded `set -eux`. A scenario `check()` failure already fails the release, and
  that must stay true.
- **No `continue-on-error`, no `if: always()`, no `if: failure()` publish path** on the
  compare step or the `release` job. A failed gate stops publication; that is the
  change.
- **No bypass for the same-binary refusal.** A re-dispatch on the same day and commit
  produces a byte-identical binary, whose compare `_perf/compare.tl:262-267` refuses;
  that run cannot publish anyway (the tag already exists). Leave it refusing.
- **No local-versus-release comparison anywhere** — no workflow step and no acceptance
  command that compares a locally built binary against a release asset. Baselines are
  release-runner measurements and only comparable to release-runner measurements.
- **No AGENTS.md edit** (498/500 lines) and no new decision record. The operator
  runbook is the text the failing step prints.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/workflows_test.tl` ends `test: PASS (1 file)` and
  prints `all workflow ratchet tests passed`, with the new
  `test_the_release_perf_compare_propagates_its_verdict` among the tests run.
- `bin/cosmic --make test _perf/gate_test.tl` ends `test: PASS (1 file)` — unchanged,
  and the standing proof that a regression surviving triage exits nonzero
  (`test_real_regression_survives_triage_and_fails`, _perf/gate_test.tl:129).
- `grep -c pipefail .github/workflows/release.yml` prints `2` (was `1`: the existing
  one is the `set -euxo pipefail` in "the binary says what it is").
- `grep -c 'exit 0' .github/workflows/release.yml` prints `1` (was `2`: the compare
  step's is deleted, the size step's stays).
- `bin/cosmic --make run _perf/baseline.tl --repo whilp/cosmic --out o/perf/prev/perf.json`
  ends `perf-baseline: OK ` naming the newest release carrying a `perf.json` asset
  and writes that file — the baseline this gate reads is really there. (Writes only
  under `o/`, which is gitignored.)

## Enablement

none needed. The one wrong turn with teeth — laundering the gate's exit status through
`| tee` — is already a stated convention in AGENTS.md ("Never launder a gate's exit
status through a pipe"), this body specifies the replacement shell verbatim, and the
`_build/workflows_test.tl` assertion is this change's own verification of it rather
than a lint policing the implementer. The publication slice it depended on (#1121) is
closed and its asset is live, so no blocker remains.


---
_Generated by [Claude Code](https://claude.ai/code)_