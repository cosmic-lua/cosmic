# CI driver

`ci/` is a project of its own inside the checkout, distinct from cosmic's
own tree: the outer build excludes its modules and tests, but walks its
files for TODOs ([input policy](https://github.com/cosmic-lua/cosmic/blob/main/build/identity.tl)). The
pinned host never tries to rebuild itself from the candidate. It is run in
place by the pinned, digest-verified host, with cwd `ci/`, so the host's project root is `ci/`
itself. `cosmic_ci/` is its Teal namespace; `testdata/` holds fixture input
and is excluded from module and test discovery. Its working database lands
in `ci/`'s build directory, outside the checkout, where
[build/paths.tl](https://github.com/cosmic-lua/cosmic/blob/main/build/paths.tl)
names it.

`bin/cosmic-bootstrap` downloads and verifies the pinned host, caching it by
digest under `$XDG_CACHE_HOME/cosmic/bootstrap`, and tries a failed download
again up to `COSMIC_BOOTSTRAP_ATTEMPTS` times (1 to 20, default 5). Each run
hashes the cached binary against the pin again, a cache actions/cache restored
among them, and an entry point holds the cached release it runs to the digest it
is named by. CI sets `COSMIC_BOOTSTRAP_VERIFY`, which refuses a stand-in, and
links the result to a runner path
(`$RUNNER_TEMP/bin/cosmic-driver`, which CI then puts on `PATH` via
`GITHUB_PATH`). Each job does so through one step, the local
`.github/actions/cosmic-driver` action, which restores that cache and
runs `.github/scripts/cosmic-driver.sh`. CI then runs the driver in
place, with cwd `ci`: `cosmic-driver cosmic_ci/driver.tl ...`.
`COSMIC_BOOTSTRAP` names another host in place of the pin's, as it does for
bin/zig; it is refused alongside `COSMIC_BOOTSTRAP_VERIFY`, which asks for the
pin's own.

The pinned release reads the new grammar by default, and
the CI driver is put on the job's PATH by a two-line wrapper that runs the entry
point (below), so the release reads `ci/`, the scripts `bin/cosmic-bootstrap` runs and the
ones `build/zig.tl` runs on that release's binary (`build/patch.tl`,
`build/zig_fetch.tl`, `build/seeded_boot.tl`) in the new checker's grammar, held to every rule and to
no ceiling. `islands.txt` lists nothing: the pinned release reads a file it
lists as Teal. CI's `check-islands` command (`cosmic-driver
cosmic_ci/driver.tl check-islands`) checks each of those scripts with
`--standalone --check` on the running driver (it type-checks the file without
running it), and fails on a syntax error or any finding. The driver's own
tests compile only the modules they require, so `check-islands`
also runs the release's `fix --check` over all of `ci/`.

Which files run standalone on the pinned release is `ci/bootstrap-files.txt`,
and it is enforced where the run happens, not found by reading the tree. What
holds, and what does not:

- `bin/cosmic-bootstrap` refuses `--standalone <file>` on a file of its checkout
  the list does not name, and the same under `COSMIC_STANDALONE=1` with `<file>`
  as the first word. The target and the checkout are compared as `cd -P` and
  `pwd -P` resolve them (a `..` after a linked directory is the physical one),
  a link in the file's name followed, so a link from outside does not get
  around it. A target whose directory cannot be resolved, `--standalone` with
  no file, and a checkout with no list are refused. A file outside the
  checkout is not held. The `sandbox` verb, which runs any program, is refused.
  A first word `<file>.tl` alone builds the tree around the file, which is how
  CI runs `cosmic-driver cosmic_ci/driver.tl` from `ci/`: allowed for a file
  under `ci/` and outside the checkout, refused for any other file of the
  checkout. (Under `ci/`, a file in a hidden directory or `testdata/` is
  allowed too, though no run reaches it as a project file.) The other verbs
  that take files or a project (`test`, `fix`, `build`, `db`, `lsp`, `compile`,
  `-e`) type-check what they read themselves or act on the project at the
  caller's working directory, which CI sets to `ci/`; nothing enforces the
  directory.
- With no argument it prints an entry point, not the release: a small script,
  one for each checkout path and release, at
  `$XDG_CACHE_HOME/cosmic/bootstrap/entry-<sha256>`, that makes the same check
  and then runs the release without fetching it again, and leaves no
  `COSMIC_BOOTSTRAP` variable in the release's environment. Entries accumulate
  there and are never pruned. `$(bin/cosmic-bootstrap)` in
  `.github/scripts/cosmic-driver.sh` (the `cosmic-driver` every job puts on its
  PATH) and `.github/scripts/run-local-proof.sh` hold one, so a run by either is
  held. **The guard holds every caller that takes the documented paths.** It is
  convention, not enforcement, for anything else: `bin/cosmic-bootstrap
  --raw-path` prints the release's own path (its only caller is
  `ci/cosmic_ci/bootstrap_test.tl`, which reads and copies the binary), and the
  release's binary is reachable in the cache and to any process running on it.
  Deliberate use of the raw binary is a review matter.
- `check-islands` type-checks each listed file on the release (`--standalone
  --check`, which does not run it). It fails on a
  listed file that is gone, on a `build/zig.tl` `standalone(` call that names a
  file the list lacks or does not name one in a string literal on its line, and
  on a list without `build/paths.tl`. It also runs the release's `fix --check`
  over all of `ci/`, which the driver's tests, compiling only what they
  require, do not. `build/ci_tree_test.tl` holds the list to
  `ci/strict-files.txt`.
- The list is read one way in shell, in [`Islands.paths`] and in
  `build/ci_tree_test.tl` (which cannot require `ci/`): one path a line, what a
  `#` starts dropped, white space trimmed from both ends.
- A refusal of a type error names the file, the list and the pinned release, and
  says to use only that release's APIs or move the pin.

What is not covered. A process running on the release can run its own binary
(`Proc.executable()`, `Proc.relaunch()`), so no wrapper or entry point can stop
it. The users of the binary's own path found by reading every `Proc.executable` and
`Proc.relaunch` of `ci/` and the tree's scripts are these; a new one is the
residual below:

- `build/zig.tl`, which runs `build/patch.tl`, `build/zig_fetch.tl` and
  `build/seeded_boot.tl` that way: its `standalone(` calls are counted, and
  each file must be in the list.
- `build/seeded_boot.tl`, which starts the release again to compile the
  seed (`Proc.relaunch`), and starts the repository's newest release, a
  binary it fetched, with `--standalone` on itself to ask where that
  release's core is (`COSMIC_BOOT_SEED=pin` keeps it to the pinned one).
  That binary is not the pinned one, and nothing but the release's own
  SHA256SUMS vouches for it; it is hashed again each time it is taken from
  the cache, against a stale or poisoned cache, not a racing writer.
- `check-islands` ([`Islands.complaint`]), which checks the listed files.
- [`BuildPaths.directory`] in [`cosmic_ci/build_paths.tl`], which runs
  `build/paths.tl` that way as the build directory's resolver (checked to be
  listed). [`BuildPaths.driver`] refuses a `--standalone` of its own.
- `ci/run_local.tl`, which starts only `build/paths.tl` that way and cannot use
  ci/'s modules: it runs standalone, which finds none.
- `ci/run_local_proof.tl` (`Proc.relaunch()`), which reads and hashes the cached
  binary; it runs the proof's runner through the entry point it is given, so
  that run is held.
- [`BuildPaths.driver`] itself, where the driver's command line is made
  (`Proc.relaunch()`, and `Proc.executable()` where there is no launcher): it
  starts nothing, and its callers are the ones listed above.
- `cosmic release get --cache` (`cosmic/cli/release.tl`), which writes the verified binary
  into the bootstrap cache; it runs no file.
- Relaunches that run no file standalone (a project, a verb):
  [`cosmic_ci/orchestration.tl`] runs `cosmic test`, `cosmic_ci/cache_trim.tl`
  runs `cosmic cache trim`, and [`Islands.project`] runs `fix --check`. The
  `*_test.tl` files of `cosmic_ci` start the driver on fixtures they write
  themselves, in directories of their own, outside every checkout.

A new site in `ci/` that relaunches the driver on a file is the residual:
nothing catches it, and code review does. A type error in such a file is
caught, because all of `ci/` is checked on the release; its run is not. Every
other file of the checkout reaches the release through the wrapper or the entry
point, or through code review.

## running the platform job locally

`ci/run-local` runs the platform job's phases (`build` through `portable-boundary`) on
this machine, for its own target, with this checkout's own tool (the one
`bin/cosmic` runs) as the driver instead of the pinned release. It
snapshots the working tree, tracked and untracked files alike, into a
fresh candidate outside the checkout, removes the build directory the
last candidate built in, sets the variables a workflow job
would, and seeds the zig caches from the
project cache every checkout shares (`COSMIC_ZIG_CACHE`, default
`~/.cache/cosmic/zig-project`). A full run takes a few minutes. The driver runs from a
copy of this checkout's `ci/`, fixtures included, taken each time run-local
starts, so after one full run `ci/run-local fixtures` re-runs edited
fixtures against the same products. Each phase's log is under
`$COSMIC_CI_LOCAL/logs/` (default `${TMPDIR:-/tmp}/cosmic-ci-local-<uid>/<key>`,
keyed by the checkout's path, so worktrees can run at once). Each run on
that default records its checkout in `<key>.source` beside its state, and
removes the state of every recorded checkout that is gone. A state with no
record, as each made before records were, stays until deleted.

Like gating CI, run-local sets `COSMIC_CI_FIXED_POINT=skip` unless the
caller sets it, so `fixtures` skips the fixed-point regression. Gating CI
skips it as its slowest fixture; on a host of four CPUs its compiles also
outlast the 340 s per-test bound. Any other value, such as `run`, runs it.

The `sandbox` phase writes what spawn's sandbox can hold on this machine
(`build/sandbox_probe.tl`) to its log and the summary, and fails only when
`COSMIC_CI_REQUIRE_SANDBOX=1` and a part a confined test needs did not hold:
that probe alone is fatal, and a test skipped for a part the host lacks
fails no `cosmic test` run, held or not.
ci.yml sets it on the Linux legs, whose container is given what the sandbox
needs; run-local leaves it unset, since many a development host refuses an
unprivileged user namespace (Ubuntu 24.04's
`kernel.apparmor_restrict_unprivileged_userns=1`, most containers), so the
phases after it still run there. Set it to hold a local run to the same.

Each leg also promises the host requirements cosmic_ci/capabilities.json
lists for it (a `requires` name of a test module's policy): the driver
gives every suite's `cosmic test` the list as `COSMIC_TEST_PROMISES` and
the leg's name (`COSMIC_WORKER`) as `COSMIC_TEST_LEG`, and a held run
fails a module whose promised requirement is absent. A worker that is no
leg's (provenance, fuzz) promises none, and `run-local` sets neither
variable, so a local run only reports. `bin/cosmic fix --check .` fails a
requirement no leg promises.

Where `COSMIC_CI_REQUIRE_SANDBOX=1`, every phase's `cosmic test` runs each
worker sandboxed to its declared inputs (`COSMIC_TEST_SANDBOX=1`), under
a `cosmic.sandbox` policy (`build/test_policy.tl`), as it does by default
wherever it can, and fails where none can be rather than run them
unsandboxed.

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
hand-over. See `.github/workflows/ci.yml` for the exact step order, and
"the workflow", below, for the container's options and why each is needed.

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
`COSMIC_WORKER` (the workflow sets this from `matrix.leg`, or to
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

[`Runner.phase`] owns the start and completion records of a platform or
provenance phase. The orchestration callback chooses its work and returns
an integer exit status; nested commands and in-process steps keep their
own operation records. A returned failure keeps its status without another
diagnostic. An exception records exit code 1 and its full text, also written
to stderr. The operations database stays outside the candidate checkout.

A command that fails says why again where a reader finds it
([`cosmic_ci/failures.tl`]): the lines of its output that say what failed
(a test's or the tree check's `FAIL`, a checker's, C compiler's, linker's
or git's error, an uncovered C function, a timeout) become `::error::`
annotations and a block of the job's summary page, and are kept in
`$RUNNER_TEMP/cosmic-ci/failures.txt`. A failed leg's step "say again what
failed" (`driver.tl failures`) prints them just before the tree is moved
back, so the log ends near the failure. The phases' build and check
commands, as a suite does, keep their output in files beside the
operations database (`said/`), which they say whole once they end. Each
such command, and each suite and fixture, is named while it runs, in a file of `running/` beside the
database, so a job cancelled or timed out under it still has the step
print the end of what that command said.

Each suite a platform phase runs -- the native (`local`) suite, the
checked and portable suites, and each fixture's `cosmic test` -- writes
one row to the operations database's `suite_runs` table once it ends
([`cosmic_ci/suite_output.tl`] reads it from the suite's stdout): how it
ended (`timeout` where the driver ended it, which keeps only the key
parts; `fail` for any other nonzero exit, a passing summary notwithstanding;
else `pass`, or `unreported` where it printed no summary), its exit
status, its tests, `ran`, `stood`, `shared` and
elapsed ms from `cosmic test`'s summary line, the key parts
(host kernel, host, system, runtime, compiler, harness, ...) its
`--census` key-parts line says, which every suite of the tree is run
with, and, in `held`, what its `test: census:` line says the verdict
cache it restored held: each set of key parts the cache's rows were
kept under, and how many rows (`1994 rows under host kernel ...,
harness e1t60000; 3 rows under no parts named`, or `no rows`). A
fixture that builds a checkout does not share its verdicts. Product,
runtime, launcher and identity fixtures declare the artifacts they read;
their keys follow those contents. The noexec fixture does too on Linux;
its unsupported operation is omitted on macOS, where ordinary launcher
coverage remains. `summarize` appends these rows as a second table. The driver's self-check (`cosmic-driver
test cosmic_ci`) is a step of its own and writes none.

A fixture can leave figures with [`Fixture.figure`]. The job log shows them,
each prefixed with the fixture's name, after the fixture runs. They appear
only when the fixture actually runs, not when its verdict stands.

`compiles-trim SINCE [RESTORED]` and `verdicts-trim SINCE|whole` are ci.yml's, run
on every leg before its caches are saved. CI selects the cache
`COSMIC_BUILD_CACHE` names, or every `.db` beside the file
`COSMIC_VERDICT_CACHE` names, and the cutoff SINCE in Unix seconds.
The running driver's build-free `cache trim` owns the formats, deletion,
and digest/fresh calculation ([`cosmic_ci/cache_trim.tl`]). It cuts supported
tables to rows used since the cutoff; `whole` and verdict caches this run
never reached are retained whole. Unknown tables and unreadable caches are
retained and reported. CI publishes save outputs only from a complete,
validated report; a failed or incomplete maintenance/comparison withholds
them, while the step remains best effort.

`digest=<hex>` in `$GITHUB_OUTPUT` is a SHA-256 of the retained rows, every
column but `used_ns`, which each run stamps again. The save's key is the
cache's prefix and that digest, so a run that kept only rows already saved
names that entry's key again and saves nothing new. Only a push to main
and the scheduled run save these caches; every run restores the newest
main saved, except where its own ref holds an entry under the same prefix
saved before only main saved, which GitHub searches first, until that
branch or entry goes. Given RESTORED, a copy of what the leg restored
made before its builds, a complete comparison also publishes
`fresh=<n>`, how many retained compiles that copy lacks. CI owns the snapshot's cleanup and retains it if its identity
cannot be established safely.

`report [--runs N] [--event E] [--branch B] [--repo OWNER/NAME]
[--workflow FILE]` is for a person, not a workflow: it reads the last N
(1 to 100, default 10) completed runs of ci.yml of event E (default
`merge_group`; a `push`'s default to branch `main`; a branch may hold
`/`) of the repository
(`$GITHUB_REPOSITORY`, else cosmic-lua/cosmic) through GitHub's REST API
([`cosmic_ci/github_api.tl`], at `$GITHUB_API_URL`, api.github.com by
default), authenticated by `$GH_TOKEN`, else `$GITHUB_TOKEN` (with gh,
`export GH_TOKEN=$(gh auth token)`): each run's
jobs and step times (`.../runs/<id>/jobs`) and the `suite_runs` rows of its
unexpired `ci-driver-<leg>` artifacts, the newest of each name -- a re-run's
latest attempt's -- fetched by id (`.../artifacts/<id>/zip`, whose redirect
the client follows itself, sending the token to the API alone). It prints, per run
newest first, the wall time of its slowest platform job
(`started_at`..`completed_at`, which leaves out queueing), the sum of
its jobs' times, each leg's time and slowest steps, each suite's row
(ran, stood, the share stood, ms), and whether it qualifies: its
checked and native suites keyed their tests by a runtime and harness
that rows of the verdict cache it restored were kept under too, as its
`held` census says them, so the commit moved neither the core nor the
harness from what the cache held. A row from before the census, or
whose restored rows name no parts (kept before rows named them), is
compared instead with the same leg's in the next older run with such
rows that was not cancelled, only the likeliest to have saved that
cache. Up to ten runs older than the N shown are listed for that, and
fetched only until one has rows, so each of the N can qualify. Then the medians over the qualifying
runs that succeeded. A run from before `suite_runs`, or whose artifacts
have expired, is reported from its step times alone and qualifies for
nothing. [`cosmic_ci/report_test.tl`] drives it against a fake
transport, and [`cosmic_ci/github_api_test.tl`] drives the client over
`cosmic.http`'s scripted replies; neither reaches the network.

`prerelease-stage` and `prerelease-publish` are prerelease.yml's publish
job, which runs after each green ci run on main, checks out only `ci/`,
`bin/cosmic-bootstrap`, `.github/scripts/cosmic-driver.sh` and the
`.github/actions/cosmic-driver` action that runs it, and holds a
`contents: write` token.
The token reaches only the driver's `prerelease-publish` step, whose client
([`cosmic_ci/github_api.tl`]) sends it to the API and to the one origin that
takes release uploads (uploads.github.com, derived from `GITHUB_API_URL`),
and to no other host; beyond the actions, the job otherwise runs only the
scripts that fetch the pinned driver and verify it against the pin. The
candidate product it downloads is data only, never executed.
`prerelease-stage` reads `PRODUCTS` (the downloaded
`portable-product-<lane>` directories, all four), `RELEASE`,
`SOURCE_COMMIT` and `SOURCE_RUN_URL`, checks that every lane executed the
same bytes, and writes the release under `RELEASE`: `cosmic`,
`SHA256SUMS`, `source.json` and `notes.md`. `prerelease-publish` reads
`GH_TOKEN` (else `GITHUB_TOKEN`), `REPOSITORY`, `RELEASE`, `SOURCE_COMMIT`,
`SOURCE_RUN_PREFIX` and `RUNNER_TEMP` (and `GITHUB_API_URL`, if set), and makes the staged release the
immutable `<YYYYMMDD>-<commit>` prerelease, or verifies the one already there
(or, where GitHub refuses the job's token the tag with an HTTP 403
"Resource not accessible by integration" and the default branch's
workflows differ from the commit's, makes nothing and prints a warning:
that commit has no prerelease, and a pin moves to a later one);
it resumes an interrupted draft only by accepting assets identical to the
staged ones, and writes its downloads under `$RUNNER_TEMP/prerelease/`.
The tag's `YYYYMMDD` is the UTC day of the commit's committer date, read
from the API (`GET repos/<repository>/commits/<commit>`) before anything
is made, so a rerun of the same commit gives the same tag; it is not the
day of the run or of the publication. There is no semver and no alias
that moves, and nothing here marks a release as the latest: the maintainer
promotes one by hand. Releases tagged `next-<commit>`, which every one
before this naming is, stay as they are: `bin/cosmic-bootstrap` takes a
pin naming either form, and `cosmic release` finds both. Nothing prunes
old prereleases.
[`cosmic_ci/prerelease_test.tl`] drives it against a fake transport, and
[`cosmic_ci/github_api_test.tl`] drives the client's uploads and asset
downloads over `cosmic.http`'s scripted replies; neither reaches the
network.

`prerelease-follow` is prerelease.yml's `follow` job, which runs after a
push run on main that passed or failed and after a full run's failed first
attempt, checks out main's tip, only what `publish` does, and holds an
`actions: write` and `issues: write` token, which only the pinned driver running main's own `ci/` uses. After a green push run, where no daily or manual run of main
that may still publish (one going, one that passed, or a first attempt
that failed and is tried again) started in the last six hours, it starts
a manual run of main
(`POST .../workflows/ci.yml/dispatches`), so a prerelease follows main
within hours. After a daily or manual run's first attempt failed, it
re-runs that run's failed jobs once, so one flaky test does not cost the
prerelease; a second failure stands. After a red push run, it opens the
issue "main is red", naming the run and its commit, where the bot has none
open, so a break on main is seen within minutes; the next green push run
comments which run passed and closes it. It reads the triggering run's
`EVENT`, `CONCLUSION`, `ATTEMPT`, `RUN_ID`, `BRANCH` and `HEAD_SHA`, with `REPOSITORY` and
`GH_TOKEN`; [`cosmic_ci/prerelease_follow_test.tl`] drives it against a
fake client.

`prerelease-sweep` is prerelease.yml's `sweep` job, which runs after each
push run of main and each hour (GitHub may start a scheduled run hours
late). A full run
that `follow` starts with the job's own token fires no workflow_run when
it ends, since GitHub starts no workflow from an event that token caused,
so neither `publish` nor `follow` sees it end; nor does a daily run that
`follow` re-ran with that token. The sweep looks at the newest full run of
main that token last started, within the last day: where it passed and no
release's tag ends in its commit, it writes `run_id` and `head_sha` to
`$GITHUB_OUTPUT`, and `publish` publishes that run; where its first
attempt failed, it re-runs the failed jobs once. It reads `REPOSITORY`,
`GITHUB_OUTPUT` and `GH_TOKEN`; [`cosmic_ci/prerelease_sweep_test.tl`]
drives it against a fake client.

`requeue` is requeue.yml's, which runs after each merge queue run of ci
that passed and acts as the whilpbot App (a token of the workflow's own
would start no queue run), for a run's first attempt only. The queue
sometimes drops an entry just as that entry's own run passes, and does not put it back; the entry's
auto-merge goes with it. [`cosmic_ci/requeue.tl`] reads the pull request
the run tested, its timeline and the runs of ci, and puts it back in the
queue where it is open, not a draft and not in conflict, the queue itself
took it out after that run began and began no later run of it, its head
is a branch of this repository that a pull request run of it tested
before it was last added, and this job
put it back fewer than twice; a pull request still in the queue is read
again a few times first. [`cosmic_ci/requeue_test.tl`] drives it against a fake
client.

`fuzz` and `fuzz-cancelled` are fuzz.yml's, and record no operation.
`fuzz` runs the sanitized tool (`sanitized/bin/cosmic` in the build
directory `build/paths.tl` names) as `test --all` from `GITHUB_WORKSPACE`
over every `*_fuzz_test.tl` outside its top-level `o/`, `vendor/` and
`ci/`, with the environment it was given (`FUZZ_SEED` and `FUZZ_ITERS`
among it), `TMPDIR` at `$RUNNER_TEMP/fuzz`, `COSMIC_AUTO_BOOT=0`,
`COSMIC_TEST_TIMEOUT=1200` and `FUZZ_SECONDS=120` unless the environment
names another (the seconds a property may spend drawing inputs, so that
one costing a tenth of a second an input on this core draws what fits
and says how many, instead of running past the test's limit). Both its
streams go to
`$RUNNER_TEMP/fuzz.out`, copied to the job log as they are written; its
status goes to `$RUNNER_TEMP/fuzz.status` and is the command's own. The
step summary gets the seed, and on a failure the failing tests' lines
and the reports beneath them, and the tests that ran five minutes or
more (`test: slow:` lines, said as each ended). `fuzz-cancelled` appends
to the step summary, and says again in the job's log, the last progress
line of `$RUNNER_TEMP/fuzz.out` (which names the tests still running,
longest first, and how many have failed), the slow tests, and the last 40
lines, if there is an output. Both write the summary where `summarize`
does.

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

`review` is review.yml's, the weekly agent review, apart from ci.yml's
weekly run. It records no operation. It starts `cosmic-driver agent ask`
on Opus at high effort, with `--sandbox=off`, told to follow
[`agents/weekly-review.md`]. It needs `ACTIONS_ID_TOKEN_REQUEST_URL`,
`ACTIONS_ID_TOKEN_REQUEST_TOKEN`, `RUNNER_TEMP` and `GITHUB_WORKSPACE`.
Before the agent starts, it lets unprivileged user namespaces be made
and runs `gh auth setup-git`. While the agent runs, it writes a fresh
GitHub OIDC token every 4 minutes, for the agent to trade for a Claude
token. It ends the agent at 130 minutes or on a signal. The job's log
gets the agent's reply and its `cosmic:` complaints, not the agent's
tool calls. The header of review.yml says when it runs and what the
agent may do; [`cosmic_ci/review.tl`] says why the token is refreshed
and the tool calls are kept out of the log. [`cosmic_ci/review_test.tl`]
drives it against a fake host.

## the workflow

`.github/workflows/ci.yml` says what each step does; this is why.

### what runs where

The merge queue gates a merge and runs what main's push runs, so a
commit that would turn main red fails its queue entry instead. The
queue also runs macOS's native suite; main's push, the daily run, a
manual run of main and one that asks for it (`macos`) add macOS's whole
leg. A
branch's push runs nothing.

- **a push to a branch** runs no CI. The merge queue tests every change
  before it lands, and the author's local checks (`bin/cosmic fix`,
  `bin/cosmic test`, `ci/run-local`) are the branch's (the tree's
  `doc/contributing.md`). A **manual run** (`workflow_dispatch`) of a
  branch runs what main's daily run does but macOS, unless it asks for
  it (`-f macos=true`), and runs the checked and narrowing suites in the
  queue's shares.
- **a pull request** runs the lightest check, the `ci` check the merge
  queue requires of a pull request before it takes it: linux-x86_64's leg
  boots the tree, runs its native suite, and checks the tree's
  format over the paths the pull request changed since its merge base with
  main (driver.tl changed-paths, `fix --check --changed`, which lays out
  only those and makes every check spanning files, the markers held to
  that base among them, over the whole tree). Where a path it changed
  reaches the launcher and startup fixtures (the list in
  `cosmic_ci/changed_paths.tl`: `build/launcher.tl`, `core/startup.c`,
  `ci/fixtures/` and the like), or the paths changed are not known, it
  also builds the artifacts and runs those fixtures, which nothing else
  before main's push runs. Beside it, `linux-x86_64-driver` (the
  `driver` job) boots nothing and checks the pinned CI driver where those
  paths reach what its tests read (`ci/`, `.github/`), as the queue's
  does, so a ci/ change that breaks `cosmic_ci`'s own tests fails here
  and not in a queue entry. Once the pull request is not a
  draft, `macos-aarch64` (part `suite`) runs macOS's native suite and
  darwin suite, as the queue's does; marking it ready runs the check
  again. GitHub gives no job a priority, so a draft's pushes leave the
  few macOS runners to the queue. Both native
  suites stand on main's verdicts ([`cosmic_ci/orchestration.tl`]'s
  `standing_events`), so they run only the tests the change reaches. A
  failure the queue would meet on those legs shows on the pull request
  first, before the change takes a queue slot: a macOS-only test, for one,
  or a test of the built binary's verbs. It saves nothing.
  A batch's pull request (a branch of this repository named
  `claude/batch-*`, stacked by `build/batch.tl` from members whose newest
  `ci` passed) runs no leg and no driver check, and its gate passes: the
  merge queue tests the batch on every leg. The skip goes by the
  branch's name alone. The run it skips takes 22 min (p50) of each
  batch's way to main.
- **the merge queue** (`merge_group`) runs what a push to main runs:
  every Linux leg and the checked and narrowing jobs. Each leg is two jobs
  at once, each booting the tree: `<leg>` (part `suite`) runs the native
  suite and its boundary, the darwin suite, the sandbox probe and the
  credential proofs; `<leg>-product` (part `product`) runs assemble, the
  regressions, the portable suite, the attestation and the product.
  alpine-x86_64's product, the longest, is two jobs, each assembling:
  `alpine-x86_64-portable` (the portable suite, the attestation and the
  product) and `alpine-x86_64-regressions`.
  `macos-aarch64` (part `suite`) runs macOS's native suite and darwin
  suite: macOS's failures were met only by the daily run, and each held
  up the prerelease. Beside
  them `linux-x86_64-format` (part `format`) checks the bootstrap's
  scripts and the tree's format over the paths the commit changed since
  main, as a pull request does, and `linux-x86_64-driver` (the `driver`
  job) boots nothing and checks the pinned CI driver where those paths
  reach what its tests read (`ci/`, `.github/`). `macos-aarch64` checks
  it there too, before its suites: its tests start the host's programs,
  which macOS keeps elsewhere (`/sbin/sha256sum`), and a break only
  macOS meets showed before only in the next daily or manual run. The checked suite runs
  in three shares at once (`linux-x86_64-checked-1` to `-3`,
  `cosmic test --shard`), so it is not the entry's longest job; a share
  does not check the C functions, which main's push does. The checked
  narrowing suite runs in three shares too
  (`linux-x86_64-checked-narrowing-1` to `-3`): whole, standing on no
  verdict, it reached its deadline. The gate
  compares the three products. An entry takes as long as its longest job. Main moves
  only through the queue, so its check of what changed holds main's whole
  tree.
- **a push to main** runs all four legs whole, macOS among them (the
  native suite, the credential proofs, assemble, the regressions, the
  portable suite, the attestation and the product), the checked core's
  whole suite (`checked`) and the whole suite on a checked run
  (`narrowing`), and the gate compares the four products
  (`COSMIC_CI_PRODUCTS=4`). So each commit that lands is tested in full on
  every platform within about 25 min, where the queue ran only macOS's
  native suite. Its macOS job stands on the queue's macOS verdicts and
  saves macOS's caches (zig, its build outputs, compiles, verdicts) for
  the queue's next runs: only the daily run saved them before, and the
  queue's macOS job booted cold. It publishes nothing yet. It repeats neither
  the format check nor the pinned driver's, which the queue made of the
  very commit; the daily run checks the driver on every leg, and the
  weekly and a manual run check the whole tree's format too. Each leg
  stands on the verdicts its queue job reached for the commit.
- **the daily scheduled run** and **a manual run** of main (or one with
  `macos`) run all that and the macOS leg, and the gate compares the four products, which
  prerelease.yml publishes: a prerelease is tested on all four legs, and
  some hours behind main (`prerelease-follow`, below). The daily run and a manual run stand on the
  verdicts main's pushes left, as a push does (`COSMIC_CI_EVENT`); Sunday's,
  the weekly run, stands on none, runs the fixed-point regression, and
  builds zig's caches cold. A manual run with `every_test` stands on none
  either, and one with `fixed_point` runs that regression too. macOS
  keys its verdicts by the tree's path, which stays the leg's own in a
  run that stands on verdicts and moves with the commit in the weekly run
  (`driver.tl place-tree`), so its daily run saves verdicts and its
  weekly run, which saves none, catches a test that turns on the path.

Each job is a plain sequence of steps on one runner, and none waits on
another but the gate; only the queue splits a leg, into its suite and its
product. Three things are relayed
between runs, by the relay (relay.yml), a workflow of its own that runs on
each push to main a minute after the merge, apart from ci.yml's pushes,
which wait on each other and save only as they end, 15 to 30 minutes
later. Each of the merge queue's legs, where its native suite passed,
trims its verdicts to what it used and uploads them with the name of the
cache its host keeps them in (`queue-verdicts-<leg>`, kept a day;
`driver.tl verdicts-name`). The relay finds that run (`driver.tl
queue-run`, the job's `actions: read`), restores main's newest verdicts of
that cache (`driver.tl verdicts-key`), merges the queue's into them
(`driver.tl verdicts-merge`, [`cosmic_ci/queue_verdicts.tl`]) and saves
them; main's push of the commit takes them in too, before its suites. The
queue's run saves no cache, its caches scoped to its ref, so without the
relay the next queue entry stood on main's last save, a commit or more
behind, and ran its whole native suite where that commit moved a key. A
row stands only for a test whose key is the same, so the relay decides how
many tests stand, never whether one is right, and no step of it fails a
job. No queue run saves a cache, but a queue ref's name comes again
where a pull request is queued again on the same commit of main, and a
run restores its own ref's caches before main's; a cache there was saved
by code the queue ran, perhaps an earlier head that never merged, whose
archive a restore extracts over the checkout. So every job that restores
a cache waits on the `queue-ref` job, which restores none and fails a
queue run whose ref holds one (`driver.tl queue-ref-caches`), and the
`ci` gate lists them again once every job has run, for a cache written
while the run ran. A cache GitHub evicted before the second listing goes
unseen.

A queue leg that failed uploads the rows it used too
(`queue-tried-verdicts-<job>`, kept a day). A checked shard and the
narrowing suite upload theirs whether they pass or fail, and a release
leg's suite that passed left its rows as `queue-verdicts-<leg>`. The
next try of the same pull request finds the newest failed run that has
ended and holds that job's artifact, or else that leg's
(`driver.tl queue-tried-run`), and merges it in before its suites, so a
suite the deadline stopped (COSMIC_TEST_DEADLINE) keeps its passes for
that try. The code a run ran can write any row, so it takes a
run only where GitHub's record shows that run ran merged code and this
try's change: the commit its entry was put on is on main (a queue commit
holds the entries ahead of it too, and one dropped from the queue never
merges), and its commit changes the same files, by name, name before,
content and mode, as this try's does (an earlier head of the pull request never
merges either). The run's `queue-ref` job and the gate's second listing
must both have passed, and its ref must hold no cache now. Only a run's
first attempt counts (an attempt again keeps the earlier one's artifacts
and jobs), and the download takes the one artifact the lookup checked,
by its id.
The queue's format job, where its check passed, seals the memo of the
tree checks (the shared rows of `build/check_memo.tl`, in the cache
directory: `driver.tl checks-seal` keeps the rows the run used, in one
file with no write-ahead log) and uploads it (`queue-checks-linux-x86_64`);
the relay downloads it, holds it to a memo with rows, and saves it
(`checks-linux-x86_64-<sha>`, [`cosmic_ci/checks_seal.tl`]). The format
check of a pull request or a queue entry restores the newest, so the tree
checks check again only the files its rows do not cover: from cold they
take some 3.5 minutes. Each queue leg also uploads the compiles and
parses it trimmed (`queue-compiles-<leg>`); the relay, a job a leg, saves
them (`compiles-<leg>-queue-<sha>`), and main's push boots on them in
place of the entry it restored, so a pull request or a queue entry that
boots soon after a merge takes them rather than compiling the tree from
cold (about a minute).
No other markers, products or verdicts reach main's push: the queue's
product jobs and its checked and narrowing jobs relay nothing to it, so
it runs those rows again.

`COSMIC_CI_SAVES` is `true` only for a push to main and the scheduled runs,
the only runs that save a cache, and is decided in the top-level `env`. The
driver does not read it (it is `COSMIC_CI_*`, which a suite's workers are
never given).

The platform job's `include` is an expression that chooses a list by the
kind of run (linux-x86_64 for a draft pull request, and macOS's suite beside it for one that is not; for the
queue every leg but macOS as its suite and its product, linux-x86_64's
format check and macOS's suite; all four for a push to main, the daily run and a manual run of main or with `macos`; every leg but macOS for another manual run),
each listing every job: an `include` entry naming a leg
no dimension holds would start that leg anyway (GitHub adds an entry that
fits no combination as one of its own). Each entry names the job
(`name`), the host it is (`leg`: its caches, its verdicts,
`COSMIC_WORKER`) and what of the leg it runs (`part`: `all`, or the
queue's `suite`, `product` or `format`). build/workflows_test.tl reads each list as
GitHub would.

A newer manual run supersedes a branch's, but every main run finishes and
main's pushes run
one at a time, in one concurrency group, so the caches they save land in
commit order. The relay (relay.yml) saves apart, a minute after each
merge, so a leg's push of a commit main has moved past saves no
verdicts or compiles (`driver.tl main-newest`): its save, made later, would
be the newest and lack the newer commit's. So the rows the relay does not
carry (the portable suite's, the regressions') reach a leg's cache from a
push still at main's head when its leg ends, and run again until one is. GitHub keeps one pending run per group and cancels it when a
third arrives, so a commit that lands while main is busy and another run
waits gets no run. The scheduled runs have a group of their own: pending
behind a push, the next push would cancel one. A manual run has a group per ref: it saves nothing, so in
main's group it could cancel a pending push, or be cancelled by one.
Batching the merge queue (its group size, a repository setting) divides
the queue's and main's runs by the group's size.

### the Linux legs' container

spawn's sandbox (`core/process.h`'s `Sandbox`) confines a test's child
in a new user namespace, where it mounts, unveils and goes offline. A
Linux leg's container needs these relaxations for it, and no more; a
probe, as uid 65534, of the ubuntu and alpine images on ubuntu-24.04
(x86_64) and the ubuntu image on ubuntu-24.04-arm (aarch64) found every
part (landlock, offline, unveil, unveil+offline, and a seccomp filter) held with all
of them, and each item says what failed without it:

1. The host's `kernel.apparmor_restrict_unprivileged_userns=1` (GitHub's
   hosts set it) withholds a new user namespace's capabilities from a
   process no AppArmor profile lets have them: with it on, no container
   option let any part that needs a namespace hold. `leg-container.sh`
   turns it off before the container starts.
2. Docker's default seccomp profile allows `unshare`, `mount`, `umount2`
   and `mount_setattr` only with `CAP_SYS_ADMIN`, and `pivot_root` to
   none, so a user namespace is refused with EPERM.
   `seccomp-profile.sh` narrows `.github/seccomp/default.json` (moby's
   default at a pinned commit, checked by its sha256) to allow just
   those five, not `seccomp=unconfined`, which drops every other rule.
3. Docker's default AppArmor profile denies mount: with the narrowed
   seccomp profile alone, unveil still failed with EACCES. So the
   container runs unconfined by AppArmor.
4. Docker's masked `/proc` paths keep a confined child from a procfs of
   its own, so the container starts with `systempaths=unconfined`.

The runner creates a job's `container:` before any step runs, so
neither the sysctl nor the profile could be set up for it; a step starts
the container instead, with `--init`, as the job's was (a process-group
kill leaves orphans, and the suite checks they are gone, not zombies
nobody collects). The runners are ephemeral VMs.

### the leg's host

Every declared-key verdict's key holds what of the host no file on it
tells (`COSMIC_HOST_ID`, `build/declared_key.tl`'s `host_identity`): on
a Linux leg its image and how it is started (all of it
`leg-container.sh`'s and `seccomp-profile.sh`'s, which are hashed), and
the engine's version; on macOS the runner's image label. Not ci.yml,
whose every edit would move it. The verdict cache is also named by the
series of the kernel's release ([`cosmic_ci/host_id.tl`]), as every key
holds it: `7.0` of both `7.0.0-1014-aws` and `7.0.0-1017-azure`, the
builds ubuntu-24.04 runners land on, so those runners share one cache
and their verdicts. A build or version string of one series is in
neither the name nor a key. The processor's
features are in neither the name nor a key, but for the key of a module
that declares `cpu_features` (doc/testing.md, "processor features"), so
runners of other processors restore one cache; the step logs the kernel
and the features it read, to show which differs. The step was "name the leg's container", as
`leg-container.sh` still calls it: an edit to that file moves every
Linux leg's `COSMIC_HOST_ID`, and so its verdicts, which an edit to
ci.yml does not, so the stale name waits for its next real change.

### the caches

An entry is keyed by its content, saved by main's runs (`COSMIC_CI_SAVES`)
and restored by every run, the newest by prefix: a leg's verdicts (named
by its host, below) and its compiles and parses, each trimmed to the rows
the run used since its start and named by their digest
([`cosmic_ci/cache_trim.tl`]), so a run that reached only what it restored
saves nothing new; the zig build outputs, once per vendor and core part
and leg, pruned to what a current build reads first
([`cosmic_ci/zig_prune.tl`]); and the pinned zig and the driver's
bootstrap, by their pins. A restore decides only how many tests stand,
never whether a verdict or a compile is right: every row is keyed by its
own inputs.

The weekly run stands on no verdict, so a pass a flake left in main's
newest entry is checked again within a week; a run that fails a test
takes that test's row out of the entry it saves.

### artifacts

`ci-driver-<job>`, `portable-product-<job>` and
`platform-diagnostics-<job>` (named by the job, `matrix.name`, so the
queue's two jobs of one leg keep theirs apart) are kept seven days. The `ci` join reads
the products within the run, and prerelease.yml as the run completes;
a re-run of either job more than seven days later cannot download them.
`report` reads the driver databases, so its suite rows cover about the
last week; a run whose artifacts expired it reports from its step times
alone.

A download that fails its job (the `ci` join's products and
prerelease.yml's) is tried
twice, because the artifact service fails a request now and then and a
failure ejects a queue entry. The first try tolerates failure. Where it
failed, a step removes the target directory and sleeps 30 seconds, and the
second try runs without that tolerance, so a failure of both fails the
job. The action retries its own requests and extractions a few seconds
apart; the pause is for an outage longer than that.

The removal matters because a pattern that matches one artifact extracts
into `path` itself, not a subdirectory, so the listing of one try can lay
out `path` differently from the other's.

A name that is absent fails the download. A pattern that matches nothing
succeeds (v8 logs "Total of 0 artifact(s)"), so there the second try
changes nothing and the consumer fails: `provenance` ("no product to compare") and `prerelease-stage` on the
products. A download that tolerates failure and has no second try is left
as it is.

`build/workflows_test.tl` holds every workflow to this: a download that
fails its job is the second try of an earlier one with the same inputs,
the first tried once, with the clearing and sleeping step between them.

[`cosmic_ci/cache_trim.tl`]: cosmic_ci/cache_trim.tl
[`cosmic_ci/prerelease_test.tl`]: cosmic_ci/prerelease_test.tl
[`cosmic_ci/prerelease_follow_test.tl`]: cosmic_ci/prerelease_follow_test.tl
[`cosmic_ci/prerelease_sweep_test.tl`]: cosmic_ci/prerelease_sweep_test.tl
[`agents/weekly-review.md`]: agents/weekly-review.md
[`cosmic_ci/review.tl`]: cosmic_ci/review.tl
[`cosmic_ci/review_test.tl`]: cosmic_ci/review_test.tl
[`cosmic_ci/github_api.tl`]: cosmic_ci/github_api.tl
[`cosmic_ci/github_api_test.tl`]: cosmic_ci/github_api_test.tl
[`cosmic_ci/report_test.tl`]: cosmic_ci/report_test.tl
[`cosmic_ci/failures.tl`]: cosmic_ci/failures.tl
[`cosmic_ci/suite_output.tl`]: cosmic_ci/suite_output.tl
[`cosmic_ci/zig_prune.tl`]: cosmic_ci/zig_prune.tl

[`BuildPaths.directory`]: cosmic_ci/build_paths.tl
[`BuildPaths.driver`]: cosmic_ci/build_paths.tl
[`cosmic_ci/build_paths.tl`]: cosmic_ci/build_paths.tl
[`cosmic_ci/checks_seal.tl`]: cosmic_ci/checks_seal.tl
[`cosmic_ci/host_id.tl`]: cosmic_ci/host_id.tl
[`cosmic_ci/orchestration.tl`]: cosmic_ci/orchestration.tl
[`cosmic_ci/queue_verdicts.tl`]: cosmic_ci/queue_verdicts.tl
[`cosmic_ci/requeue.tl`]: cosmic_ci/requeue.tl
[`cosmic_ci/requeue_test.tl`]: cosmic_ci/requeue_test.tl
[`Fixture.figure`]: cosmic_ci/fixture.tl
[`Islands.complaint`]: cosmic_ci/islands.tl
[`Islands.paths`]: cosmic_ci/islands.tl
[`Islands.project`]: cosmic_ci/islands.tl
[`Runner.phase`]: cosmic_ci/runner.tl
