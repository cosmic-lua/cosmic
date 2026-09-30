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
([`cosmic_ci/suite_output.tl`] reads it from the suite's stdout): how it
ended (`timeout` where the driver ended it, which keeps only the key
parts; `fail` for any other nonzero exit, a PASS line notwithstanding;
else `pass`, or `unreported` where it printed no summary), its exit
status, its tests, `ran`, `stood`, `shared` and
elapsed ms from `cosmic test`'s summary line, the key parts
(host features, host, system, runtime, compiler, harness, ...) its
`--census` key-parts line says, which every suite of the tree is run
with, and, in `held`, what its `test: census:` line says the verdict
cache it restored held: each set of key parts the cache's rows were
kept under, and how many rows (`1994 rows under host features ...,
harness e1t60000; 3 rows under no parts named`, or `no rows`). A
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
([`cosmic_ci/cache_trim.tl`]). The save's key is the cache's prefix and
that digest, so a run that kept only rows already saved names that
entry's key again and saves nothing new. Only a push to main and the
scheduled run save these caches; every run restores the newest main
saved, except where its own ref holds an entry under the same prefix
saved before only main saved, which GitHub searches first, until that
branch or entry goes.

`verdicts-merge DIR` is ci.yml's too, run in a merge queue run before
its suite: it adds each `.db` in DIR, the verdicts the queue's run
ahead kept (the run ahead, below), to the cache of the same name beside
the file `COSMIC_VERDICT_CACHE` names, making it where there is none.
It is a union, table by table of the tool's formats: a row whose
primary key the cache holds already is left as it is, and no row is
made that neither file held, so a second merge adds nothing. A row
added is stamped used at 0, by no run, so the trim keeps it only where
this run's suite stood on it. A table of another shape, or with no
primary key, is left and said so; a cache it cannot merge is said so,
and never fails the step.

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
nothing. [`cosmic_ci/report_test.tl`] drives it against a fake `gh`
([`testdata/report/gh.tl`]) and never reaches the network.

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
[`cosmic_ci/prerelease_test.tl`] drives it against a fake `gh`
([`testdata/prerelease/gh.tl`]) and never reaches the network.

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

## the workflow

`.github/workflows/ci.yml` says what each step does; this is why.

### scope, saves and concurrency

The workflow decides two things once, in its top-level `env`:
`COSMIC_CI_SCOPE` is `full` for the merge queue, main (a push, the
scheduled run) and a manual run, and `light` for a branch push;
`COSMIC_CI_SAVES` is `true` only for a push to main and the scheduled
run, the only runs whose platform legs save a cache (a push to main
that reuses the queue's run saves through `seed`, below). The driver
reads neither (both are `COSMIC_CI_*`, which a suite's workers are
never given).

A newer push supersedes a branch's run, but every main run finishes (a
prerelease is published only from a completed run) and main's pushes
run one at a time, in one concurrency group, so the caches they save
land in commit order and a restore's newest entry is never an older
commit's saved late. GitHub keeps one pending run per group and cancels
it when a third arrives, so a commit that lands while main is busy and
another run waits gets no run and no prerelease; a pin moves to a later
one. A push that reuses the queue's run takes a minute or two, so that
needs three landings that close together. The scheduled run has a
group of its own: pending behind a push, the next push would cancel it.
Running beside main's pushes its saves can land after a newer
commit's, which costs the next run only the rows that commit moved,
never a wrong one. A manual run has a group per ref: it saves nothing,
so in main's group it could cancel a pending push, or be cancelled by
one. Pushes to the merge queue's `gh-readonly-queue/`
branches are ignored: they run as `merge_group`, and a push run there
would share its group and cancel it, which the queue reads as a failure.

### the queue's result

main takes changes only through the merge queue, whose `merge_group`
run tests the very commit the push to main then names, with the same
full scope. A push to main reuses that run rather than test it again.
Only a main ref's run can save what branches and the queue restore (an
entry saved under `gh-readonly-queue/` is that ref's alone), and
prerelease.yml publishes a main run's products, so the push still
saves and still carries the products, both taken from the queue's run:

- Each leg of a queue run that passed keeps what main would save
  (`queue-seed.sh stage`): its trimmed verdicts and compiles, where
  they differ from the entry it restored, and the driver check's marker,
  where the check ran, with `seed.keys` naming the key each is saved
  under, the key main's own save would compute. It uploads them as
  `seed-<leg>`, kept a day. The checked job (below) keeps its verdicts
  the same way, as `seed-linux-x86_64-checked`.
- A push to main first runs `reuse` (`queue-seed.sh find`), which asks
  the API for a `merge_group` run of ci.yml on a
  `gh-readonly-queue/main/` branch whose `head_sha` is the push's, that
  completed with success and holds an unexpired `seed-<leg>` for every
  leg and the checked job. The queue lands the merge as its `ci` check passes, a moment
  before its run completes, so a run still in progress, or an API call
  that failed, is asked after again, every 20 s up to six times, each
  call cut off at 15 s; the job's timeout is held above that budget. A
  lookup that fails, or times out, is none: the legs run, and the join
  reads only theirs.
- Where it finds one, the platform legs and the checked job are
  skipped, and `seed`, on each leg's own runner (an entry's version
  hashes its path, the runner's), saves that leg's seed under the keys
  it names and uploads the queue's `portable-product-<leg>` as this
  run's; its checked entry saves the checked job's verdicts and relays
  no product. The `ci` join
  compares those products as it does a platform run's, reading `seed`'s
  result in place of the legs' and the checked job's, and
  prerelease.yml publishes them
  unchanged. The prerelease's `source.json` names this run, whose
  `reuse` summary names the queue's run that built and tested the
  product (the `TODO:` on `seed`'s relay).
- Where it finds none (a direct push, or a lookup that failed), and on
  the scheduled and a manual run, which skip `reuse`, the legs run the
  full scope and save as before. Only a push to main runs `reuse`: a
  branch push shows it as a skipped check rather than hold its legs
  for a runner's start with nothing to do (seconds, up to about 100 s
  in a burst of runs); the legs' `!cancelled()` runs them past a
  skipped `reuse` as past one that found nothing. `seed` too shows as
  a skipped check on a branch push (a `TODO:`).

What the push gives up is a second run of the same commit: a flake the
queue's run missed is no longer caught on main, where the nightly run
still runs every test. A seed decides only how many tests stand: every
row is keyed by its own inputs. The zig build outputs are not seeded:
main saved them only on the first run after a vendor change, which the
nightly's cold build and save now does alone. Until then a branch or a
queue run restores the leg's newest entry of another vendor part (the
second restore) and recompiles only what moved, and main has no run
that builds but a direct push's or a manual one's. Seeding them too
would move some 130 MB a leg through an artifact for the few hours
before the nightly.

### the run ahead

Entries stacked in the queue run at once, each on the one before it:
an entry's base is the head of the run ahead of it, which main has not
saved verdicts of yet, so its restore takes main's newest, a change or
more behind, and where the change ahead moved a part every key holds,
it runs nearly every test again. A cache cannot pass between them (an
entry is saved under its own ref, which no other reads), so an
artifact does: each leg of a queue run uploads its native suite's
verdicts as `verdicts-<leg>` the moment the suite passes, kept a day,
and the checked job its checked suite's as
`verdicts-linux-x86_64-checked`. Before its suite, a queue run's leg
asks the API for the run ahead (`queue-seed.sh ahead`): the
`merge_group` run on a `gh-readonly-queue/main/` branch whose
`head_sha` is its base. Where that run holds the leg's artifact, the
leg downloads it and merges it into what it restored (`verdicts-merge`,
above), between its boot (`platform boot`) and its native suite
(`platform local-suite`, the `build` phase's suite, which run-local
still runs with its boot as `build`). While the run ahead is in
progress and its leg has not completed, it asks again every 15 s, for
two and a half minutes at most. The checked job waits a minute and a
half at most, and not at all for a checked job ahead that will not
have kept its verdicts by then, some seven minutes after it started.
A run, or its leg, that completed without the artifact, a base that
heads no queue run (main's already, whose verdicts the restore took; a
restore of the base's own entry skips the lookup), a change that moves
build/harness_epoch.tl (every test runs, standing on none) and a
failed step are all none, and the suite stands on what was restored.
Only verdicts pass so, never compiles or the driver check's marker,
and only from a suite that passed.

### the checked job

The checked core's suite, the whole suite on the sanitized core, ran
at the end of linux-x86_64's assemble: 178 to 345 s after that leg's
own suites, which made it the queue's longest leg in 9 of 13 runs
(2026-09-29). It runs instead in a job of its own, `checked`
(`linux-x86_64-checked`), beside the legs, on that leg's host: its
runner, image and builder, and so the same `COSMIC_HOST_ID`. It boots
(`platform boot`, the build phase without the native suite), builds the
checked core and the format decoder the contract's fixture would have
left (`platform checked-build`), and runs the suite (`platform
checked`). Every leg sets `COSMIC_CI_CHECKED_SUITE=skip`, and still
builds and verifies its checked core in assemble, which its fixtures
use; a leg that skips the suite removes a `checked.db` from its
verdicts, which would otherwise ride along whole in each save.

It runs wherever the legs do. On a branch push (`light`), which runs
no checked suite, every step skips, so it shows as a check that ran:
a runner's start, which the join waits for, and no skipped check. It
restores linux-x86_64's zig build outputs and compiles, which that leg
saves, and saves neither. Its verdicts it keeps under a name of its
own, `verdicts-linux-x86_64-checked-<host>-<features>-<digest>`,
restored, trimmed, saved on `COSMIC_CI_SAVES` and seeded as a leg's
are. The `ci` join requires it, and `report` counts it with the legs.
Its tree moves to a path of the commit's own, as a leg's does: the
checked core runs the harness, the boot's staging and `tool.tl entry`
unsandboxed at that path, so a path of another length each commit
varies what the sanitizers see. The tree moves back before the seed
and the verdicts' save, whose path actions/cache names relative to the
workspace (below).

### the Linux legs' container

spawn's sandbox (`core/process.h`'s `Sandbox`) confines a test's child
in a new user namespace, where it mounts, unveils and goes offline. A
Linux leg's container needs these relaxations for it, and no more; a
probe, as uid 65534, of the ubuntu and alpine images on ubuntu-24.04
(x86_64) and the ubuntu image on ubuntu-24.04-arm (aarch64) found every
part (landlock, pledge, offline, unveil, unveil+offline) held with all
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
processor features a core chooses code by and the kernel's release and
version (`host-features.sh`), which differ between runners of one leg:
named by the container alone, a run restored another runner's cache and
none of its verdicts stood. The step was "name the leg's container", as
`leg-container.sh` still calls it: an edit to that file moves every
Linux leg's `COSMIC_HOST_ID`, and so its verdicts, which an edit to
ci.yml does not, so the stale name waits for its next real change.

### the caches

An entry is keyed by its content, saved from one place and restored
everywhere else. Only `COSMIC_CI_SAVES` runs (and `seed`, for a push
that reuses the queue's run) save the verdicts, the
compiles and parses, the zig build outputs and the driver check's
marker (the pinned zig and the driver's bootstrap are saved by any run
that misses their exact key, which names only the pin). A branch or the
merge queue restores main's and saves nothing: a PR's later pushes
stand on main's entries, not its earlier push's. GitHub searches a
ref's own entries before main's, so a branch's entry saved before only
main saved still wins over main's newer one under the same prefix.
Which entry a restore takes decides only how many tests stand, never
whether a verdict or a compile is right: every row is keyed by its own
inputs.

The verdicts and the compiles are trimmed to the rows the run used
since its start and saved under their prefix and a digest of those
rows, so a run that reached only what it restored names that entry
again and saves nothing new. Saved whole, a leg's verdicts came to about
40 MB compressed a main push, most of it under keys no later run
reaches, since every change to `build/` moves every key; trimmed, 8 to
13 MB. The cost: main's saved file holds only its newest commit's keys,
so a branch based on an older main whose keys a `build/` change has
since moved would run every test again. So main also saves each job's
verdicts under its commit, `<prefix>sha-<commit>`, even where their
content is an entry's already (`seed` too, from the key
`queue-seed.sh stage` names), and each restore asks first for the
entry of the tree's base on main (`.github/scripts/merge-base.sh`: a
branch's merge base with main, through the API; the merge queue's
base), then the newest. Those copies, one a leg and the checked job
each main push (some 11 MB each), would fill the repository's 10 GB
within days and evict the zig outputs (below), so ci.yml's `prune`
job deletes those more than a day old on each push to main
(`.github/scripts/prune-commit-verdicts.sh`, with the one token in
ci.yml that may write the cache, `actions: write`); a branch based on
an older commit restores main's newest. A run that failed keeps what it
restored with what it reached (`whole`). The compiles are saved only
where the native build and suite passed.

zig's caches are restored outside the checkout, at the same path every
run, since zig keys what it compiles by path. There is one entry per
leg, even where two legs share a target: two legs saving one key in
parallel means only one ever wins, and the other restores a cache
another host built. An entry is never replaced under its own key, so
each save takes one of its own:

    zig-build-<leg>-<vendor>-<scope>-<core>-<run>-<attempt>

`vendor` hashes what compiles the vendored libraries (the pin,
`build.zig`, `build/zig.tl`, `vendor/`, `patch/` and its applier, the
configuration headers they read from `core/`) but not the trees zig
never compiles (tl, tzdata, cacert). `core` hashes the core's own C.
`scope` is `full`, where assemble passed; a `light` entry, saved before
only main saved, is still restored last. The restore takes the newest
entry for this vendor part (`full` with this core part, else `full`,
else any); off main, where none has this vendor part, a second step
takes the leg's newest of any, since in one step a ref's own older entry
would win over main's.

Main saves an entry only where assemble passed and it had nothing
`full` for this vendor part, so once per vendor part and leg, not once
per core change; a push that reuses the queue's run builds nothing and
saves none, so that is now the nightly's (the queue's result, above).
The scheduled run restores nothing, compiles cold and saves a compact
entry. An entry saved per core change would be past the
repository's 10 GB cache at main's rate: a whole entry is about 0.5 GB
for the four legs, and it grows with each save, since zig never prunes
its cache and a save carries all it restored. When main saved after
every run, GitHub evicted the least recently used entries, the fuzz
job's and other legs' own among them, which then built cold. The
nightly cold build is what bounds an entry. The cost: a vendor change's
first main run builds cold (minutes a leg), and a core change is
compiled again, incrementally, by every run after it until the nightly
save. Where assemble fails on the first main run after a vendor change,
nothing is saved, so every main run builds vendor/ cold until one
passes assemble or the nightly saves; a branch stays warm through the
restore of another vendor part.

actions/cache archives with `tar -C $GITHUB_WORKSPACE` and a path
relative to it (`../../_temp/...`), which names nothing through the
link `place-tree.sh` leaves were the tree more than one directory deep.
So the tree moves only to a directory beside the workspace, whose name
the commit and the leg choose, and the saves run with it moved; it
moves back at the end for checkout's post step, whose git refuses a
repository at another path and leaves its credentials behind. The move
means a test whose verdict turns on the tree's path meets it on the
macOS leg (unsandboxed; a Linux leg's workers see the tree at /tree)
only where its key moved or on the scheduled run, which stands on
nothing; the TODO on `build/test.tl`'s `launch` would give such a
worker a fixed path.

The CI driver check's marker is keyed by what cosmic_ci's tests read
(`ci/`, `bin/`, the scripts, the driver action and ci.yml) and the
leg's host; an exact hit skips the check, except on the scheduled and
manual runs.

### artifacts

`ci-driver-<leg>`, `portable-product-<leg>` and
`platform-diagnostics-<leg>` are kept seven days. The `ci` join reads
the products within the run, and prerelease.yml as the run completes;
a re-run of either job more than seven days later cannot download them.
`report` reads the driver databases, so its suite rows cover about the
last week; a run whose artifacts expired it reports from its step times
alone.

[`cosmic_ci/cache_trim.tl`]: cosmic_ci/cache_trim.tl
[`cosmic_ci/prerelease_test.tl`]: cosmic_ci/prerelease_test.tl
[`cosmic_ci/report_test.tl`]: cosmic_ci/report_test.tl
[`cosmic_ci/suite_output.tl`]: cosmic_ci/suite_output.tl
[`testdata/prerelease/gh.tl`]: testdata/prerelease/gh.tl
[`testdata/report/gh.tl`]: testdata/report/gh.tl
