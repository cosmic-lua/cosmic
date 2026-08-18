Imported from whilp/cosmic#1134.

## Goal

G5 — adversarial verification, via epic #1125. goals.md's measure is fuzzers that
"exist and run on a cadence"; the per-PR runs are shallow by design (256 iterations),
so depth needs its own schedule.

## Change

Four decisions are settled below and written into the diff; nothing here is left to
the implementer's judgement.

**Settled: seed policy.** One seed per run, from the WORKFLOW env, never from a clock
read inside a test: the lane computes `FUZZ_SEED` as `date -u +%Y%m%d` (a rotating
integer, e.g. `20260817`), overridable by a `workflow_dispatch` input for replay. Every
module in a run gets the same seed, so ONE line reproduces the whole lane. The seed is
recorded three times: a `deep-fuzz: seed= iters=` line on stdout before the run,
the same line plus a copy-pasteable reproduce command in `$GITHUB_STEP_SUMMARY`, and
`seed=` inside any driver failure message (`_fuzz/driver.tl:66-69`). Tests stay
deterministic given their environment, and the declared-env stamp from #1156 makes that
environment a real cache input.

**Settled: failure routing.** The lane fails loudly and the run is the artifact: no
auto-filing, no comment, no `issues: write`. The driver's message already carries
`seed=`, `iteration=` and `input(base64)=`, the step summary carries the reproduce
command, and `o/_fuzz/*.test.err`/`.out`/`.time` upload as an artifact so the failing
input survives log truncation. Dedup is structural — one scheduled run per day means one
notification stream, not N issues. Auto-filing was rejected: it needs a write-scoped
token in a lane that runs arbitrary tree code, a board `comment` verb that does not exist
(#1204, still `work:plan`), and a dedup key nobody has designed. Turning a finding into a
regression test stays a human/agent step, which is G5's other measure.

**Settled: budget.** One uniform `FUZZ_ITERS=50000` for the whole lane (195x the 256
default), `2000` on the pull_request trigger. Uniform rather than per-module because
`_fuzz/driver.tl:81` reads a single `FUZZ_ITERS`, and `_make/envstamp.tl:73-88` writes
every declaring file's stamp on every invocation regardless of selection — so per-module
values would invalidate the modules run under a different value and re-execute them for
nothing. Depth chosen to clear the deepest real find by a margin: the url `format`
fixpoint property first failed at iteration 18,602 (#1156's evidence), and 50,000 gives
2.7x headroom. Measured on the refinement host (`o/bin/cosmic` at `a3cd318`, one module
per process, `FUZZ_SEED=20260817`) — host-dependent, so not a facts-block claim:

| module | 2,000 iters | 20,000 iters | 50,000 iters |
|---|---|---|---|
| compress | 1,739 ms | 15,810 ms | 38,463 ms |
| json | 105 ms | 1,106 ms | 2,638 ms |
| re | 245 ms | 2,384 ms | 5,458 ms |
| sse | 357 ms | 3,608 ms | 8,373 ms |
| tar | 3,263 ms | 37,836 ms | 82,376 ms |
| url | 289 ms | 2,647 ms | 6,264 ms |
| **total** | **5,998 ms** | **63,391 ms** | **143,572 ms** |

Linear in `FUZZ_ITERS` (10x iterations, 10.6x time), all six green at 50,000. The whole
suite is 2.4 minutes of property time here and `tar` is 57% of it; at a 4x derate for a
shared runner that is ~10 minutes, plus fetch and the converging build. Hence the caps:
`timeout-minutes: 30` on the deep step and `timeout-minutes: 45` on the job — the lane
finishes or dies loudly, and a future property that turns superlinear hits a timeout
instead of hanging.

**Settled: placement.** A dedicated `.github/workflows/fuzz.yml` with its own cron, NOT
a step in `release.yml`. `release.yml`'s `build` job is one `set -eux` chain feeding
`release`, so a deep-fuzz step there either fails the release (a fuzz find must never
block shipping) or is guarded with `|| true` (a lane that cannot fail is not a lane).
Its own workflow also gets its own cadence, its own timeout, its own concurrency group,
and read-only permissions.

```facts
$ ls -1 _fuzz/*_fuzz_test.tl
_fuzz/compress_fuzz_test.tl
_fuzz/json_fuzz_test.tl
_fuzz/re_fuzz_test.tl
_fuzz/sse_fuzz_test.tl
_fuzz/tar_fuzz_test.tl
_fuzz/url_fuzz_test.tl
$ ls -1 _fuzz/*_fuzz_test.tl | wc -l
6
$ grep -c "driver.run({" _fuzz/*_fuzz_test.tl
_fuzz/compress_fuzz_test.tl:3
_fuzz/json_fuzz_test.tl:3
_fuzz/re_fuzz_test.tl:3
_fuzz/sse_fuzz_test.tl:3
_fuzz/tar_fuzz_test.tl:3
_fuzz/url_fuzz_test.tl:4
$ grep -n "DEFAULT_ITERS\|DEFAULT_SEED" _fuzz/driver.tl
19:local DEFAULT_SEED = 1
20:local DEFAULT_ITERS = 256
80:  local seed = env_integer("FUZZ_SEED", DEFAULT_SEED)
81:  local iters = opts.iters or env_integer("FUZZ_ITERS", DEFAULT_ITERS)
$ grep -rl "^--- env:" _fuzz/
_fuzz/sse_fuzz_test.tl
$ ls -1 .github/workflows/
docs.yml
pr.yml
release.yml
$ grep -c "image: buildpack-deps@sha256:cfb30ff3856780c63b00ec3ad2e4aed77ae6afce5975ebb8ad9525ec45354e2e # noble (Ubuntu 24.04)" .github/workflows/docs.yml .github/workflows/pr.yml .github/workflows/release.yml
.github/workflows/docs.yml:1
.github/workflows/pr.yml:3
.github/workflows/release.yml:1
$ wc -l _fuzz/compress_fuzz_test.tl _fuzz/json_fuzz_test.tl _fuzz/re_fuzz_test.tl _fuzz/tar_fuzz_test.tl _fuzz/url_fuzz_test.tl
  143 _fuzz/compress_fuzz_test.tl
  166 _fuzz/json_fuzz_test.tl
  246 _fuzz/re_fuzz_test.tl
  305 _fuzz/tar_fuzz_test.tl
  291 _fuzz/url_fuzz_test.tl
 1151 total
```

1. **`.github/workflows/fuzz.yml`** (new, one job, ~90 lines including comments).
   `docs.yml` is the skeleton — single containerised job, prepare-builder, fetch, run:
   - Triggers: `schedule: - cron: '0 9 * * *'` (daily, three hours after release.yml's
     `0 6 * * *`, so the two lanes never contend and a find lands on a tree that already
     shipped); `workflow_dispatch` with two string inputs, `seed` and `iters`, both
     defaulting to `''`; and `pull_request: branches: [main], paths:
     ['.github/workflows/fuzz.yml', '_fuzz/**']`, so the lane's own plumbing is proven on
     the PR that adds it and on every later `_fuzz` change.
   - `permissions: contents: read` and nothing else.
   - `concurrency: group: fuzz-${{ github.event_name == 'pull_request' && github.ref ||
     github.run_id }}`, `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`
     — PR runs supersede, scheduled runs never cancel each other.
   - Job `fuzz`: `runs-on: ubuntu-latest`, `timeout-minutes: 45`, and a container block
     whose `image:` and `options:` lines are copied BYTE-IDENTICALLY from
     `docs.yml:31-33`. `_build/workflows_test.tl` asserts one distinct `image:` line and
     one distinct `options:` line across every workflow, that the image is digest-pinned,
     that every non-exempt job is containerised, and that each containerised job both
     `useradd`s a `builder` and runs `runuser -u builder`.
   - Steps, in order: `actions/checkout` at the same pinned sha as `docs.yml:37`;
     "prepare non-root builder", copied verbatim from `docs.yml:39-45`; NO
     `actions/cache` step (a deep lane must never inherit a shallow run's markers);
     a `plan` step writing `seed` and `iters` to `$GITHUB_OUTPUT` — `seed` = the dispatch
     input when non-empty else `date -u +%Y%m%d`, `iters` = the dispatch input when
     non-empty else `2000` when `github.event_name == 'pull_request'` else `50000`; then
     the deep step (`timeout-minutes: 30`) which prints
     `deep-fuzz: seed= iters=`, appends that line and
     `FUZZ_SEED= FUZZ_ITERS= bin/cosmic --make test _fuzz` to
     `$GITHUB_STEP_SUMMARY`, and runs
     `runuser -u builder -- env HOME="$HOME" PATH="$PATH" FUZZ_SEED= FUZZ_ITERS=
     bash -ec 'bin/cosmic --make fetch; bin/cosmic --make test _fuzz'` under `set -eux`
     with no guard; then `actions/upload-artifact` with `if: always()`, `name:
     deep-fuzz-${{ steps.plan.outputs.seed }}`, and paths `o/_fuzz/*.test.out`,
     `o/_fuzz/*.test.err`, `o/_fuzz/*.test.time` (the base the test rule records under —
     `record $(basename $@)`, `embed/cosmic.mk:188-189`).
   - `_fuzz` as a selection path covers every file under it, current and future
     (`_make/select.tl:19-24`), so a new fuzz module joins the lane by existing. Do not
     enumerate module paths in the workflow.
2. **`--- env: FUZZ_SEED FUZZ_ITERS`** added to the five modules that lack it —
   `_fuzz/compress_fuzz_test.tl`, `_fuzz/json_fuzz_test.tl`, `_fuzz/re_fuzz_test.tl`,
   `_fuzz/tar_fuzz_test.tl`, `_fuzz/url_fuzz_test.tl` — as one line inside each file's
   leading `---` doc-comment block, exactly the shape of `_fuzz/sse_fuzz_test.tl:4`. One
   line per file; every file has headroom (facts above). Without this, five of six
   modules replay a cached shallow verdict whenever only `FUZZ_ITERS`/`FUZZ_SEED` moved,
   which is the vacuity #1156 retired for `sse` alone.
3. **`_build/fuzz_test.tl`** (new, ~50 lines) — the ratchet that keeps the lane honest,
   in the style of `_build/workflows_test.tl`. Header `--- reads: _fuzz` plus
   `--- reads: .github/workflows/fuzz.yml` (one path per line — the `reads:` grammar is
   single-token today, see Non-goals):
   - `test_every_fuzz_module_declares_its_env`: every `_fuzz/*_fuzz_test.tl` contains a
     line `--- env: FUZZ_SEED FUZZ_ITERS`; the failure message says why (a module without
     it replays a cached shallow verdict in the deep lane, so its deep PASS is a lie).
     Assert the module list is non-empty, so the loop cannot pass vacuously.
   - `test_the_deep_lane_runs_the_whole_directory`: `.github/workflows/fuzz.yml` exists
     and contains `--make test _fuzz`, so deleting or narrowing the lane fails a test
     rather than silently ending the cadence.
4. **`AGENTS.md`** — two edits, prose only: add `fuzz.yml  daily deep fuzz (--make test
   _fuzz)` to the `.github/workflows/` block (`AGENTS.md:53-56`), and a `- **fuzz.yml**:`
   bullet to the CI section beside the `docs.yml` and `release.yml` bullets
   (`AGENTS.md:493-497`) stating the cadence, the depth, the seed source, and that a red
   lane never blocks a release.
5. Ratchet clause: if the coverage or casts gate complains about the new files, run
   exactly the regen command the failure message prints and commit the result — in scope,
   and never a gate weakened any other way.

## Non-goals

- **No new properties.** The parser slices own those; this slice runs the properties that
  exist, deeper.
- **Never auto-weaken or quarantine a failing property.** No `continue-on-error`, no
  `|| true`, no `if: always()` on the deep step itself, no per-module skip list, and no
  lowering `FUZZ_ITERS` to make a red lane green. A red deep lane stays red until the
  property or the code under it is fixed.
- No edits to `_fuzz/driver.tl` or `_fuzz/driver_test.tl`. The driver's env contract is
  settled, and `driver_test.tl` deliberately carries NO `--- env:` declaration: it sets
  and restores both variables in-process, so the ambient value is ignored there by
  design. The `_build/fuzz_test.tl` ratchet checks `*_fuzz_test.tl` only, for that reason.
- No changes to `release.yml`, and no change to any job body in `pr.yml`. A deep-fuzz
  failure must never fail or delay a release, and pr.yml's lanes keep running the fuzz
  properties at the 256 default.
- The container `image:` digest line and the `options:` line are copied byte-for-byte and
  not bumped. A digest bump is its own change (it moves the coverage floor), and
  `_build/workflows_test.tl` requires every copy to agree.
- No `issues: write`, no `contents: write`, no auto-filing or auto-commenting, and
  therefore no dependency on the board's missing `comment` verb (#1204).
- No `actions/cache` step in this lane.
- No change to the `--- env:` grammar or to the `--- reads:` grammar. `reads:` is
  single-token until #1178 lands, which is why change item 3 writes one path per line
  rather than a multi-path line that would silently no-op.
- G5's win condition — "a release ships only after a clean fuzz window" — is out of
  scope. This slice establishes the cadence; gating a release on fuzz history is a later
  slice and would need this lane's history to exist first.

## Acceptance

- `bin/cosmic --make test _build/fuzz_test.tl` ends `test: PASS`.
- `bin/cosmic --make test _build/workflows_test.tl` ends `test: PASS` — the new lane's
  container, privilege and identity pins agree with every other workflow.
- **The depth setting takes effect, on a module that had no declaration before, with no
  marker deleted anywhere in the sequence:**
  ```
  bin/cosmic --make test _fuzz/tar_fuzz_test.tl                  # test: PASS
  FUZZ_ITERS=2000 bin/cosmic --make test _fuzz/tar_fuzz_test.tl  # test: PASS
  FUZZ_ITERS=2000 bin/cosmic --make test _fuzz/tar_fuzz_test.tl  # test: PASS
  ```
  Quote all three `_fuzz/tar_fuzz_test … NNNms` rows in the PR. Run 2 must be several
  times run 1 (on the refinement host: 606 ms at the 256 default, 3,263 ms at 2,000), and
  run 3 must be near-instant — the same value is the same stamp, so it replays. Deleting
  a `.got` or `.in` marker anywhere in this sequence invalidates the evidence: what is
  being proven is that the stamp alone did it.
- **A forced failure produces the routing artifact's content.** With a one-line LOCAL
  edit that makes one property fail (e.g. return `false, "forced"` from json's round-trip
  check — not committed), `FUZZ_SEED=1 FUZZ_ITERS=1000 bin/cosmic --make test
  _fuzz/json_fuzz_test.tl` ends `test: FAIL (1 test)` and the reported message matches
  `seed=1 iteration=%d+ input%(base64%)=`. Quote it. Then `git checkout
  _fuzz/json_fuzz_test.tl` and re-run to `test: PASS`, and confirm `git status` is clean
  before the PR.
- **The lane runs on this PR.** The `pull_request` trigger fires `fuzz` at
  `FUZZ_ITERS=2000`; quote the run URL, the `deep-fuzz: seed= iters=2000` line, the
  job summary's reproduce line, and the name of the uploaded `deep-fuzz-` artifact.
- `bin/cosmic --make ci` ends `ci: PASS`.
- **Provable only by running the workflow, and to be stated as such in the PR:** the
  `0 9 * * *` fire itself, the 50,000-iteration wall clock on a GitHub runner, and
  GitHub's own notification on a red scheduled run. The PR-trigger run above proves every
  other piece of the plumbing (container, non-root builder, fetch, `_fuzz` selection,
  summary, artifact upload) at shallow depth; the depth figure is evidenced by the
  measurement table above and bounded by the 30-minute step cap.

## Enablement

none needed — the mechanism this slice consumes is in the tree, and the two candidate
blockers do not bind:

- **#1156 landed** (`a3cd318`, PR #1185, closed 2026-08-17): `_make/imports.tl:222`
  `env_scan` matches `^--- env: (.+)$` and splits the capture on `%S+`, so the two-token
  `--- env: FUZZ_SEED FUZZ_ITERS` form this slice needs works TODAY
  (`_make/imports_test.tl:122` covers `--- env: A B C`); `_make/envstamp.tl` hashes the
  declared values into `o/.env/.env`; `_make/graph.tl:159-166` puts that stamp in
  `deps_`; and `embed/cosmic.mk:184-189` makes it both an mtime prerequisite and a
  `--deps` content-key input, which is what kills the D18 replay.
- **#1178 is not a prerequisite** — that fixes the single-token `--- reads:` grammar. `--- env:`
  was multi-token from the start, and this slice's `reads:` declarations are written one
  path per line so they are live either way.
- **#1204 is not a prerequisite** — the settled routing needs no GitHub write from CI, so the
  board's missing `comment` verb is irrelevant here.

  (Both bullets deliberately avoid the two-word phrase the board reads as a real
  blocker line, which is why they are worded as "not a prerequisite".)
- Enablement inside the slice: `_build/fuzz_test.tl` is the countermeasure for the
  predicted wrong turn that a future fuzz module ships without its `--- env:` declaration
  and silently replays a shallow verdict in the deep lane.


---
_Generated by [Claude Code](https://claude.ai/code)_