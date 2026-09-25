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

CI runs the driver unprivileged, and as root a permission a fixture expects
to be refused may be granted. So invoked as root, run-local runs the driver
as `$COSMIC_CI_LOCAL_USER` (default `$SUDO_USER` under sudo, else `nobody`)
through `setpriv` or `runuser`, after handing it the state directory; the
checkout stays root's and must be readable by that user. Where neither tool
exists (macOS) it warns and runs as root.

## runner users

`macos-aarch64` runs every step as the unprivileged host runner user. The
three Linux legs run in GitHub job containers (the images `ci/images/`
builds), which always execute `uses:` and `run:` steps as the container's
default user. That default user stays root -- creating the builder needs it,
and a default user whose uid differs from the host runner's would break the
checkout action's file commands -- but the driver itself, and every
`cosmic-driver` step, runs as an unprivileged `runner` user created with the
same uid as the host runner, after root hands the checkout and restored
caches over to it. See `.github/workflows/ci.yml` for the exact step order
and ownership.

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
`provenance` for the join job), and, for `platform` only, `TARGET`. All
driver state lives under `$RUNNER_TEMP/cosmic-ci/`: the operations database
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

`prerelease-stage` and `prerelease-publish` are prerelease.yml's publish
job, which checks out only `ci/`, `bin/cosmic-bootstrap`,
`.github/scripts/cosmic-driver.sh` and the `.github/actions/cosmic-driver`
action that runs it, and holds a `contents: write` token.
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
immutable `next-<commit>` prerelease, or verifies the one already there;
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

`image-build` and `image-publish` are ci-images.yml's: they run `docker`,
found on `PATH`, from `GITHUB_WORKSPACE`, record no operations and need no
`RUNNER_TEMP` state. `image-build` builds `ci/images/$IMAGE` for `ARCH` as
`ghcr.io/<GITHUB_REPOSITORY>-ci-<IMAGE>:<GITHUB_SHA>-<ARCH>`, lowercase,
with `UBUNTU_SNAPSHOT` as a build argument, and pushes it when `PUBLISH` is
`true`. `image-publish` logs in to GHCR as `GITHUB_ACTOR` with `TOKEN` on
the login's stdin (and in no argument, message or docker environment),
joins each of `ARCHES` (blank-separated) under `<GITHUB_SHA>`, prints the
index's `name@digest`, and appends it to `GITHUB_STEP_SUMMARY`.
