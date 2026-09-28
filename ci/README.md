# CI driver

`ci/` is a project of its own inside the checkout, distinct from cosmic's
own tree: it has no `core/` or `build/`, so cosmic's own build never walks
it (`build/work.tl`'s `foreign_trees`), and the pinned host never tries to
rebuild itself from the candidate. It is run in place by the pinned,
digest-verified host, with cwd `ci/`, so the host's project root is `ci/`
itself. `cosmic_ci/` is its Teal namespace; `testdata/` holds fixture input
and is excluded from module and test discovery. Its working database lands
at `ci/o/build.db` (gitignored).

`bin/cosmic-bootstrap` downloads and verifies the pinned host, caching it by
digest under `$XDG_CACHE_HOME/cosmic/bootstrap`, and tries a failed download
again up to `COSMIC_BOOTSTRAP_ATTEMPTS` times (1 to 20, default 5); CI sets
`COSMIC_BOOTSTRAP_VERIFY` so a cache actions/cache restored is checked against
the pin again, and links the result to a runner path
(`$RUNNER_TEMP/bin/cosmic-driver`, which CI then puts on `PATH` via
`GITHUB_PATH`). Each job does so through one step, the local
`.github/actions/cosmic-driver` action, which restores that cache and
runs `.github/scripts/cosmic-driver.sh`. CI then runs the driver in
place, with cwd `ci`: `cosmic-driver cosmic_ci/driver.tl ...`.
`COSMIC_BOOTSTRAP` names another host in place of the pin's, as it does for
bin/zig; it is refused alongside `COSMIC_BOOTSTRAP_VERIFY`, which asks for the
pin's own.

## running the platform job locally

`ci/run-local` runs the platform job's phases (`build` through `fixtures`) on
this machine, for its own target, with this checkout's `o/bin/cosmic` as the
driver instead of the pinned release. It snapshots the working tree, tracked
and untracked files alike, into a fresh candidate outside the checkout, sets
the variables a workflow job would, and seeds the zig caches from this
checkout's `o/`. A full run takes a few minutes. The driver runs from a
copy of this checkout's `ci/`, fixtures included, taken each time run-local
starts, so after one full run `ci/run-local fixtures` re-runs edited
fixtures against the same products. Each phase's log is under
`$COSMIC_CI_LOCAL/logs/` (default `${TMPDIR:-/tmp}/cosmic-ci-local-<uid>/<key>`,
keyed by the checkout's path, so worktrees can run at once; a removed
worktree's state stays until deleted).

The `sandbox` phase writes what spawn's sandbox can hold on this machine
(`build/sandbox_probe.tl`) to its log and the summary, and fails only when
`COSMIC_CI_REQUIRE_SANDBOX=1` and a part a confined test needs did not hold.
ci.yml sets it on the Linux legs, whose container is given what the sandbox
needs; run-local leaves it unset, since many a development host refuses an
unprivileged user namespace (Ubuntu 24.04's
`kernel.apparmor_restrict_unprivileged_userns=1`, most containers), so the
phases after it still run there. Set it to hold a local run to the same.

Where `COSMIC_CI_REQUIRE_SANDBOX=1`, every phase's `cosmic test` runs each
worker sandboxed to its declared inputs (`COSMIC_TEST_SANDBOX=1`,
`build/test_sandbox.tl`), as it does by default wherever it can, and fails
where none can be rather than run them unsandboxed.

CI runs the driver unprivileged, and as root a permission a fixture expects
to be refused may be granted. So invoked as root, run-local runs the driver
as `$COSMIC_CI_LOCAL_USER` (default `$SUDO_USER` under sudo, else `nobody`)
through `setpriv` or `runuser`, after handing it the state directory; the
checkout stays root's and must be readable by that user. Where neither tool
exists (macOS) it warns and runs as root.

## runner users

`macos-aarch64` runs every step as the unprivileged host runner user. The
three Linux legs run their actions (checkout, caches, uploads) on the host,
as the host runner user, and their `run:` steps in a container of the image
`ci/images/` builds, which a step starts with the options spawn's sandbox
needs (`.github/scripts/leg-container.sh`): each step runs there through the
`leg-shell` shell as an unprivileged `runner` user created, as root, with
the same uid as the host runner, so it owns what the actions wrote with no
hand-over. See `.github/workflows/ci.yml` for the exact step order, the
container's options and why each is needed.

Orchestration copies `cosmic_ci/` once per fixture into a separate, external
fixture project, since each fixture needs a fresh working database; each runs
on the pinned host `Proc.executable()` returns. Runner operation state is kept
in a separately checked external database. The checked-in pin
(`cosmic-driver.pin`) is the production trust root; local development may
preseed a temporary pin cache with a digest-verified locally built host, but
that does not establish release publication or immutability.

`run`, `platform`, and `provenance` read their context from the environment
rather than from positional arguments: `GITHUB_WORKSPACE` (the candidate
checkout root), `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, `RUNNER_TEMP`,
`COSMIC_WORKER` (the workflow sets this from `matrix.name`, or to
`provenance` for the join, in ci.yml's `ci` job), and, for `platform` only,
`TARGET`. All driver state lives under `$RUNNER_TEMP/cosmic-ci/`: the operations database
at `$RUNNER_TEMP/cosmic-ci/operations.db`, the platform work directory at
`$RUNNER_TEMP/cosmic-ci/platform`, and the provenance products directory at
`$RUNNER_TEMP/cosmic-ci/products`. `driver.tl summarize` needs only
`RUNNER_TEMP`, since it runs whenever the driver bootstrapped, including
after a failed self-check, when the rest of that contract may not hold; it
appends the operations table to the file named by
`GITHUB_STEP_SUMMARY` (or to stdout when that is unset); when the
operations database does not exist yet it appends a note that it is
unavailable and exits 0: no operation ran, which means the self-check
failed first.

Each suite a platform phase runs -- the native (`local`) suite, the
checked and portable suites, and each fixture's `cosmic test` -- writes
one row to the operations database's `suite_runs` table once it ends
(`cosmic_ci/suite_output.tl` reads it from the suite's stdout): how it
ended (`timeout` where the driver ended it, which keeps only the key
parts; `fail` for any other nonzero exit, a PASS line notwithstanding;
else `pass`, or `unreported` where it printed no summary), its exit
status, its tests, `ran`, `stood`, `shared` and
elapsed ms from `cosmic test`'s summary line, and the key parts
(host features, host, system, runtime, compiler, harness, ...) its
`--census` line says, which every suite of the tree is run with. A
fixture's run is keyed by nothing and says none. `summarize` appends
these rows as a second table. The driver's self-check (`cosmic-driver
test cosmic_ci`) is a step of its own and writes none.

`compiles-trim SINCE` and `verdicts-trim SINCE|whole` are ci.yml's, run
on every leg before its caches are saved. Each cuts the cache
`COSMIC_BUILD_CACHE` names, or every `.db` beside the file
`COSMIC_VERDICT_CACHE` names, to the rows the run used since SINCE, in
Unix seconds (`whole`, for a run that failed, cuts none), and writes
`digest=<hex>` to `$GITHUB_OUTPUT`: a SHA-256 of the rows it kept, every
column but `used_ns`, which each run stamps again
(`cosmic_ci/cache_trim.tl`). The save's key is the cache's prefix and
that digest, so a run that kept only rows already saved names that
entry's key again and saves nothing new. Only a push to main and the
scheduled run save these caches; every run restores the newest main
saved, except where its own ref holds an entry under the same prefix
saved before only main saved, which GitHub searches first, until that
branch or entry goes.

`report [--runs N] [--event E] [--branch B] [--repo OWNER/NAME]
[--workflow FILE]` is for a person, not a workflow: it reads the last N
(1 to 100, default 10) completed runs of ci.yml of event E (default
`merge_group`; a `push`'s default to branch `main`; a branch may hold
`/`) of the repository
(`$GITHUB_REPOSITORY`, else cosmic-lua/cosmic) through `gh`, found on
`PATH` and authenticated as it is: each run's jobs and step times
(`gh api .../runs/<id>/jobs`) and the `suite_runs` rows of its unexpired
`ci-driver-<leg>` artifacts, the newest of each name -- a re-run's
latest attempt's -- fetched by id (`gh api .../artifacts/<id>/zip`). It prints, per run
newest first, the wall time of its slowest platform job
(`started_at`..`completed_at`, which leaves out queueing), the sum of
its jobs' times, each leg's time and slowest steps, each suite's row
(ran, stood, the share stood, ms), and whether it qualifies: its
checked and native suites keyed their tests by the runtime and harness
the same leg's did in the next older run with such rows that was not
cancelled, so the commit moved neither the core nor the harness. Up to
ten runs older than the N shown are listed for that, and fetched only
until one has rows, so each of the N can qualify. Then the medians over the qualifying
runs that succeeded. A run from before `suite_runs`, or whose artifacts
have expired, is reported from its step times alone and qualifies for
nothing. `cosmic_ci/report_test.tl` drives it against a fake `gh`
(`testdata/report/gh.tl`) and never reaches the network.

`prerelease-stage` and `prerelease-publish` are prerelease.yml's publish
job, which runs after each green ci run on main, checks out only `ci/`,
`bin/cosmic-bootstrap`, `.github/scripts/cosmic-driver.sh` and the
`.github/actions/cosmic-driver` action that runs it, and holds a
`contents: write` token.
The token reaches only the driver's `prerelease-publish` step, which hands
it to the `gh` CLI; beyond the actions, the job otherwise runs only the
scripts that fetch the pinned driver and verify it against the pin. The
candidate product it downloads is data only, never executed.
`prerelease-stage` reads `PRODUCTS` (the downloaded
`portable-product-<lane>` directories, all four), `RELEASE`,
`SOURCE_COMMIT` and `SOURCE_RUN_URL`, checks that every lane executed the
same bytes, and writes the release under `RELEASE`: `cosmic`,
`SHA256SUMS`, `source.json` and `notes.md`. `prerelease-publish` reads
`GH_TOKEN`, `REPOSITORY`, `RELEASE`, `SOURCE_COMMIT`, `SOURCE_RUN_PREFIX`
and `RUNNER_TEMP`, finds `gh` on `PATH`, and makes the staged release the
immutable `next-<commit>` prerelease, or verifies the one already there
(or, where GitHub refuses the job's token the tag with an HTTP 403
"Resource not accessible by integration" and the default branch's
workflows differ from the commit's, makes nothing and prints a warning:
that commit has no prerelease, and a pin moves to a later one);
it resumes an interrupted draft only by accepting assets identical to the
staged ones, and writes its downloads under `$RUNNER_TEMP/prerelease/`.
`cosmic_ci/prerelease_test.tl` drives it against a fake `gh`
(`testdata/prerelease/gh.tl`) and never reaches the network.

`fuzz` and `fuzz-cancelled` are fuzz.yml's, and record no operation.
`fuzz` runs `o/sanitized/bin/cosmic test --all` from `GITHUB_WORKSPACE`
over every `*_fuzz_test.tl` outside its top-level `o/`, `vendor/` and
`ci/`, with the environment it was given (`FUZZ_SEED` and `FUZZ_ITERS`
among it), `TMPDIR` at `$RUNNER_TEMP/fuzz`, `COSMIC_AUTO_BOOT=0` and
`COSMIC_TEST_TIMEOUT=1200`. Both its streams go to
`$RUNNER_TEMP/fuzz.out`, copied to the job log as they are written; its
status goes to `$RUNNER_TEMP/fuzz.status` and is the command's own. The
step summary gets the seed, and on a failure the failing tests' lines
and the reports beneath them. `fuzz-cancelled` appends the last 40 lines
of `$RUNNER_TEMP/fuzz.out`, if there is one, to the step summary. Both
write the summary where `summarize` does.

`image-build` is ci-images.yml's and `image-publish` ci-images-publish.yml's:
they run `docker`, found on `PATH`, from `GITHUB_WORKSPACE`, record no
operations and need no `RUNNER_TEMP` state. `image-build` builds
`ci/images/$IMAGE` for `ARCH` as `ghcr.io/<GITHUB_REPOSITORY>-ci-<IMAGE>:<GITHUB_SHA>-<ARCH>`, lowercase,
with `UBUNTU_SNAPSHOT` as a build argument, and pushes it when `PUBLISH` is
`true`. `image-publish` logs in to GHCR as `GITHUB_ACTOR` with `TOKEN` on
the login's stdin (and in no argument, message or docker environment),
joins each of `ARCHES` (blank-separated) under `<SOURCE_COMMIT>`, the commit
of the ci-images run that built them, prints the
index's `name@digest`, and appends it to `GITHUB_STEP_SUMMARY`.
