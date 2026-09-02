# CI workflows

the four workflow files under `.github/workflows/`, what each lane
asserts, and how to read a gate result. for a contributor reading a
red check or changing a workflow.

## reading a gate result

a gate verb signals twice: the exit code, and a verdict line last on
stdout.

| verb | verdict line |
|---|---|
| `--make ci` | `ci: PASS (<n> stages)` or `ci: FAIL (<stages>)` |
| any one stage | `<verb>: PASS (...)` or `<verb>: FAIL (...)` |

the verdict line survives any truncation of the log. the exit code does
not survive a pipe: `--make ci | tail` returns `tail`'s status. run
with `set -o pipefail`, or read the verdict line.

## `pr.yml`

runs on `push` to `main`, `pull_request` against `main`, `merge_group`,
and `workflow_dispatch`. the required check names are `pr / ci`,
`pr / build`, `pr / repro` and `pr / smoke`. a newer push to a pull
request cancels the running pull-request run. pushes to `main` each
get their own concurrency group and never cancel each other.

every Linux lane runs in the same container: `buildpack-deps` at a
pinned digest (Ubuntu 24.04), `--privileged`, as a non-root user named
`builder`. `_build/workflows_test.tl` ratchets the copies of that
block identical across lanes.

### `ci`

| step | asserts |
|---|---|
| restore `o/` from cache | the key is `o-<runner os>-<workspace path>-<hash of bin/cosmic.pin>-<sha>`, so a run restores the nearest earlier run on its branch and starts cold on a pin bump or a moved workspace |
| `bin/cosmic --make fetch` | the pins resolve with the network allowed |
| `bin/cosmic --make ci` inside `unshare --net` | the whole gate passes with loopback as the only interface. `cosmic.quicksand.netns` brings `lo` up first. a download anywhere in a recipe, a build script or a test fails |
| on failure | prints every `*.test.got` with a non-zero code, its `.out` and `.err`, the last 20 lines of `o/gate.log`, and the coverage detail of each declined row |

the gate converges before it runs: the pinned release builds the tree,
then re-execs into `o/bin/cosmic`, so the five stages report on the
change. the job times out at 12 minutes and the gate step at 8; a
green run takes about 2.

### `build`

| step | asserts |
|---|---|
| fetch, build, build again | `bin/cosmic --make build` then `o/bin/cosmic --make build` produce byte-identical `o/bin/cosmic`: `fixpoint: PASS` |
| the fence is live | `require("cosmic.sandbox").availability().fs` is true, so the fenced builds above enforced something |
| upload | `o/bin/cosmic` as the artifact `cosmic-smoke` |

### `repro`

needs `build`. a fresh container, so the tree is cold by construction.

| step | asserts |
|---|---|
| copy the checkout to `$HOME/repro` and fetch there | `o/3p/tl/tl.lua`, `o/3p/cosmos/make` and `o/3p/cosmos/lua` exist |
| build twice at the new path | `o/bin/cosmic` is byte-identical to `build`'s artifact: `reproducible: PASS` |
| `o/bin/cosmic --make fetch` again | no `fetch https` line appears; a satisfied pin fetches nothing |

### `smoke`

needs `build`. runs on `macos-latest` and `windows-latest`, with the
downloaded artifact copied to `cosmic.exe`.

| step | asserts |
|---|---|
| `cosmic -e` | prints `smoke-<host os>` |
| `--docs reference.platforms` | contains `Platform support` |
| `--docs fs.read` | contains `read` |
| five portable tests run directly | `cosmic/string_test.tl`, `cosmic/json_test.tl`, `cosmic/fs/path_test.tl`, `cosmic/fs/path_normalize_test.tl`, `cosmic/fs/path_windows_test.tl` exit 0 |

the lane ends with `smoke: PASS` and times out at 8 minutes.

## `docs.yml`

runs on `push` to `main` and `workflow_dispatch`, one run at a time,
never cancelled.

| step | does |
|---|---|
| `bin/cosmic --make fetch` | resolves the pins |
| `bin/cosmic --make docs` | renders every documented source to `o/docs/<path>.md` |
| `bin/cosmic --make run _docs/publish.tl <sha> o/docs docs` | publishes `o/docs` to the `docs` branch, stamped with the source commit |

## `release.yml`

runs daily at `0 6 * * *` UTC, and on `workflow_dispatch` with two
inputs: `prerelease` (default `true`) and `perf_gate` (default `true`).
a cron run is always a prerelease; a real release needs a dispatch
with `prerelease: false`.

### job `build`

| step | asserts or produces |
|---|---|
| name the release | the tag `YYYY-MM-DD-<sha7>` |
| build twice | `bin/cosmic --make build`, then `o/bin/cosmic --make build`, with `COSMIC_VERSION` set to the tag. the release is built by its own code, not by the pin |
| the binary says what it is | `o/bin/cosmic --version` contains the tag |
| the gate | `o/bin/cosmic --make ci` under the binary being released |
| measure | `_perf/run.tl` twice: `perf.json` and `selfcheck.json` |
| compare | `_perf/baseline.tl` fetches the previous release's binary, `_perf/baserun.tl` measures it, `_perf/gate.tl compare` judges. a regression fails the job unless `perf_gate` is `false`; the first measured release is a `SKIP` |
| size | `_build/size.tl` writes `size.json` and compares against the previous release. a report, never a gate |
| upload | `cosmic`, `cosmic-debug`, the perf and size files, as `cosmic-lua` |

### job `peers`

measures the peer table with `_perf/peers/run.tl` and uploads
`peers.json` and `peers.md`.

### job `release`

publishes with `gh release create <tag>`, `--prerelease` unless
dispatched with `prerelease: false`. the assets are `cosmic-lua`,
`cosmic-lua-debug`, `SHA256SUMS`, `perf.json`, `selfcheck.json`,
`compare.txt`, `size.json`, `size-compare.txt`, `peers.json` and
`peers.md`. the notes are the last line of `compare.txt`,
`size-compare.txt` and `peers.md`.

## `fuzz.yml`

runs daily at `0 9 * * *` UTC, three hours after `release.yml`, on
`workflow_dispatch` with inputs `seed` and `iters`, and on
`pull_request` when `fuzz.yml` or `_fuzz/**` change.

| setting | value |
|---|---|
| `FUZZ_SEED` | the `seed` input, else `date -u +%Y%m%d`. dispatch with a day's seed to replay it |
| `FUZZ_ITERS` | the `iters` input, else `50000`; `2000` on a `pull_request` run |
| the command | `bin/cosmic --make test _fuzz` |
| artifacts | `o/_fuzz/*.test.out`, `*.test.err`, `*.test.time`, uploaded pass or fail as `deep-fuzz-<seed>` |
| timeouts | 45 minutes for the job, 30 for the fuzz step |

a red fuzz run fails loudly. it never blocks or delays a release.
