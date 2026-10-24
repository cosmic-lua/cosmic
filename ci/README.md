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

`islands.txt` lists the files that stay Teal until the pin moves past
the switch (doc/plans/strict-teal.md): `ci/`, the scripts
`bin/cosmic-bootstrap` runs and the ones `build/zig.tl` runs on that
release's binary (`build/patch.tl`, `build/zig_fetch.tl`). CI's `check-islands` command
(`cosmic-driver cosmic_ci/driver.tl check-islands`) gives each file of the
list to the running driver's `compile`, which parses and type-checks it
and runs nothing, and fails on a syntax error or any type error. A
directory of the list is compiled by the driver's own tests.
`build/islands_test.tl` holds the list to the tree, and is its only other
reader.

## running the platform job locally

`ci/run-local` runs the platform job's phases (`build` through `portable-boundary`) on
this machine, for its own target, with this checkout's own tool (the one
`bin/cosmic` runs) as the driver instead of the pinned release. It
snapshots the working tree, tracked and untracked files alike, into a
fresh candidate outside the checkout, sets the variables a workflow job
would, and seeds the zig caches from the
project cache every checkout shares (`COSMIC_ZIG_CACHE`, default
`~/.cache/cosmic/zig-project`). A full run takes a few minutes. The driver runs from a
copy of this checkout's `ci/`, fixtures included, taken each time run-local
starts, so after one full run `ci/run-local fixtures` re-runs edited
fixtures against the same products. Each phase's log is under
`$COSMIC_CI_LOCAL/logs/` (default `${TMPDIR:-/tmp}/cosmic-ci-local-<uid>/<key>`,
keyed by the checkout's path, so worktrees can run at once; a removed
worktree's state stays until deleted).

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

Each leg also promises the host requirements cosmic_ci/capabilities.tl
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

[`Runner.phase`] owns the start and completion records of a platform or
provenance phase. The orchestration callback chooses its work and returns
an integer exit status; nested commands and in-process steps keep their
own operation records. A returned failure keeps its status without another
diagnostic. An exception records exit code 1 and its full text, also written
to stderr. The operations database stays outside the candidate checkout.

Each suite a platform phase runs -- the native (`local`) suite, the
checked and portable suites, and each fixture's `cosmic test` -- writes
one row to the operations database's `suite_runs` table once it ends
([`cosmic_ci/suite_output.tl`] reads it from the suite's stdout): how it
ended (`timeout` where the driver ended it, which keeps only the key
parts; `fail` for any other nonzero exit, a passing summary notwithstanding;
else `pass`, or `unreported` where it printed no summary), its exit
status, its tests, `ran`, `stood`, `shared` and
elapsed ms from `cosmic test`'s summary line, the key parts
(host features, host, system, runtime, compiler, harness, ...) its
`--census` key-parts line says, which every suite of the tree is run
with, and, in `held`, what its `test: census:` line says the verdict
cache it restored held: each set of key parts the cache's rows were
kept under, and how many rows (`1994 rows under host features ...,
harness e1t60000; 3 rows under no parts named`, or `no rows`). A
fixture that builds a checkout does not share its verdicts. Product,
runtime, launcher and identity fixtures declare the artifacts they read;
their keys follow those contents. The noexec fixture does too on Linux;
its unsupported operation is omitted on macOS, where ordinary launcher
coverage remains. `summarize` appends these rows as a second table. The driver's self-check (`cosmic-driver
test cosmic_ci`) is a step of its own and writes none.

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
branch or entry goes. The one exception is a branch's compiles for its
own later pushes (the caches, below): given RESTORED, a copy of what the
leg restored made before its builds, a complete comparison also publishes
`fresh=<n>`, how many retained compiles that copy lacks, which that save
turns on. CI owns the snapshot's cleanup and retains it if its identity
cannot be established safely.

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
immutable `next-<commit>` prerelease, or verifies the one already there
(or, where GitHub refuses the job's token the tag with an HTTP 403
"Resource not accessible by integration" and the default branch's
workflows differ from the commit's, makes nothing and prints a warning:
that commit has no prerelease, and a pin moves to a later one);
it resumes an interrupted draft only by accepting assets identical to the
staged ones, and writes its downloads under `$RUNNER_TEMP/prerelease/`.
[`cosmic_ci/prerelease_test.tl`] drives it against a fake transport, and
[`cosmic_ci/github_api_test.tl`] drives the client's uploads and asset
downloads over `cosmic.http`'s scripted replies; neither reaches the
network.

`fuzz` and `fuzz-cancelled` are fuzz.yml's, and record no operation.
`fuzz` runs the sanitized tool (`sanitized/bin/cosmic` in the build
directory `build/paths.tl` names) as `test --all` from `GITHUB_WORKSPACE`
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

A `light` run has three platform legs, not four: alpine-x86_64, which
is linux-x86_64's runner and target in another image, runs on every
`full` run, the merge queue's among them. A matrix cannot read `env`, so
the legs' `name` list tests the scope's condition again and takes one
of two lists. The matrix's `include` adds each leg's values by name,
and an entry naming a leg the list leaves out would start that leg
anyway (GitHub adds an entry that fits no combination as one of its
own, `exclude` or not); so alpine-x86_64's entry names no leg, comes
first and is added to every leg, and each later entry overwrites all of
its values for its own leg (build/workflows_test.tl expands the matrix
as GitHub does, for either scope).

A `light` run also splits linux-x86_64's native suite, the longest of
its legs' (some 114 s after an edit to a carried module, 190 to 205 s
after a core change, where linux-aarch64's takes 83 s and 120 to 131 s),
between two legs: the matrix's `shard` dimension gives every leg `1/2`
and `2/2`, its `exclude` drops the second of every leg but
linux-x86_64, and `COSMIC_CI_SHARD` passes the share on to that leg's
two jobs alone (`linux-x86_64` and `linux-x86_64-shard`), whose native
suites run `cosmic test --shard 1/2` and `2/2`. The harness deals the
chosen tests in turn, in sorted order, so the two run each test once
between them whatever either restored; a deal by recorded cost would
turn on the verdict cache each restored, which two runners need not
restore alike. Each job is linux-x86_64's in all but the share: its
runner, image, caches and verdict cache, so the same key parts, and
the gate (`ci`) needs both. Neither checks that every C function is
entered, which only a whole run answers (linux-aarch64's and
macos-aarch64's light runs still do, and every leg of a `full` run).
A light run saves no verdicts, so neither share's stands for the
other's. A `full` run's `shard` is empty, and every leg runs whole.

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

### the queue's run cancels itself

On the queue's run the job `cancel` watches the run's other jobs
(`.github/scripts/cancel-on-failure.sh`, every 30 s) and cancels the
run once one has failed, naming it in an error annotation. The gate
(`ci`) has `always()`, so it still runs, and fails a minute or two
later (its runner starts), where it would otherwise wait for every leg
still running. The queue then drops
the entry and restarts the entries behind it, which wait on a run that
cannot merge.

It is a job of its own, not a step of each leg, for two reasons. Only
it holds `actions: write`, where the legs run test code with `read`. And
the failed leg has finished when the cancel comes, so it keeps its
`failure` instead of reading `cancelled`; the legs cancelled with it do
read `cancelled`, so a result at the gate may too.

A leg that has failed should also stop sooner itself. On the queue's run
each suite (`cosmic test --bail`: native, checked, portable and darwin;
`test_words`) starts no test after its first failure. The tests already
running finish with their own verdicts, so the failure list may name a
few more than one, and the tests never started keep no verdict, pass or
fail, so none stands on a later run. The suite's summary says how many
did not run (`N not run after the first failure`). The leg then fails
at once, which the `cancel` job turns into a cancelled run without
waiting on the rest of that suite. The suites run the tree's own tool,
which parses the flag, not the pinned release the driver runs on. A
push, the scheduled and a manual run, and `ci/run-local` do not pass
it: they report every failing test.

Nothing waits on `cancel`: the gate does not need it, and it names no
required check. It starts with the legs and stops when a job has failed
and the run is cancelled, when the gate starts (every leg has
finished), or after 48 minutes. A call that fails is asked again, and it
always exits 0. A cancel it fails to make leaves the legs running to the
end.

Every other run keeps its legs running to the end (`fail-fast: false`):
no entry waits on a branch's run, a leg that goes on shows every failure
at once, and main's and the scheduled run save from the legs that
finish. `cancel` shows as a skipped check there.

### the queue's result

main takes changes only through the merge queue, whose `merge_group`
run tests the very commit the push to main then names, with the same
full scope. A push to main reuses that run rather than test it again.
Only a main ref's run can save what branches and the queue restore (an
entry saved under `gh-readonly-queue/` is that ref's alone), and
prerelease.yml publishes a main run's products, so the push still
saves and still carries the products, both taken from the queue's run:

- Each leg of a queue run that passed keeps what main would save
  (`driver.tl queue-stage`): its trimmed verdicts and compiles, where
  they differ from the entry it restored, the driver check's marker,
  where the check ran, with `seed.keys` naming the key each is saved
  under, the key main's own save would compute. It uploads them as
  `seed-<leg>`, kept a day. Where it restored no entry of this core and
  vendor part, it keeps its zig build outputs too, as a tar (an artifact
  keeps no file's mode) in an artifact of their own, `seed-zig-<leg>`,
  whose failure fails nothing: they save only time. The checked job
  (below) keeps its verdicts the same way, as
  `seed-linux-x86_64-checked`; its zig build outputs are
  linux-x86_64's, whose leg keeps them.
- A push to main first runs `reuse` (`driver.tl queue-find`), which asks
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
  no product. After the relay, and failing nothing, it saves the leg's
  zig build outputs, unless an entry of their core and vendor part is
  there already (an earlier queue run's of the same core). The `ci` join
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
  a skipped check on a branch push (a `TODO:`), as do `prune` and
  `invalidate`, which act on main alone.

What the push gives up is a second run of the same commit: a flake the
queue's run missed is no longer caught on main, where the nightly run
still runs every test. A seed decides only how many tests stand: every
row is keyed by its own inputs. The zig build outputs are seeded once
per core or vendor change: without them only the nightly saved any,
and each queue run after a change to `core/` compiled the core again
on every leg and for the checked build, some four to five minutes of
the gate, where one that restores an entry of its own core boots in
seconds. Seeding them moves a leg's raw tar, larger than its cache
entry of a few hundred MB compressed, through an artifact the gate
waits to upload (at deflate's fastest), on the queue's runs that
restored no such entry.

### the run ahead

Entries stacked in the queue run at once, each on the one before it:
an entry's base is the head of the run ahead of it, which main has not
saved verdicts of yet, so its restore takes main's newest, a change or
more behind, and where the change ahead moved a part every key holds,
it runs nearly every test again. A cache cannot pass between them (an
entry is saved under its own ref, which no other reads), so an
artifact does: each leg of a queue run uploads its native suite's
verdicts as `verdicts-<leg>` the moment the suite passes, kept a day,
and each share of the checked suite (below) its own as
`verdicts-linux-x86_64-checked-shard-<part>`. Before its suite, a queue run's leg
asks the API for the run ahead (`driver.tl queue-ahead`): the
`merge_group` run on a `gh-readonly-queue/main/` branch whose
`head_sha` is its base. Where that run holds the leg's artifact, the
leg downloads it and merges it into what it restored (`verdicts-merge`,
above), between its boot (`platform boot`) and its native suite
(`platform local-suite`, the `build` phase's suite, which run-local
still runs with its boot as `build`). While the run ahead is in
progress and its leg has not completed, it asks again every 15 s, for
half a minute at most, and not at all where that leg has not begun its
native suite (`SUITE_STEP`): one not started, still building, or itself
waiting on the run ahead of it. A longer wait cost more than it saved:
in the queue of 2026-09-30, legs waited 97 and 132 s, one on a leg that
was itself waiting, where the suite stands mostly on what was restored
anyway. A share of the checked suite waits a minute and a
half at most for the share of the same part, and not at all for one
ahead that will not have kept its verdicts by then, some ten minutes
after it started (`READY_SECONDS`, a share's build and its quarter of the suite).
A run, or its leg, that completed without the artifact, a base that
heads no queue run (main's already, whose verdicts the restore took; a
restore of the base's own entry skips the lookup), a change that moves
build/harness_epoch.tl (every test runs, standing on none) and a
failed step are all none, and the suite stands on what was restored.
Only verdicts pass so, never compiles or the driver check's marker,
and only from a suite that passed.

### the checked jobs

The checked core's suite, the whole suite on the sanitized core, takes
12 to 25 minutes on one runner, and 1934 to 2326 s with its build and
the checked narrowing run behind it (the legs take 946 to 1503 s in the
merge queue; the figures here are of its runs on 2026-10-23). Run at
the end of linux-x86_64's assemble, 178 to 345 s after that leg's own
suites, it made that the queue's longest leg in 9 of 13 runs
(2026-09-29). It runs in jobs of their own, beside the legs, on
that leg's host: its runner, image and builder, and so the same
`COSMIC_HOST_ID`. Each boots (`platform boot`, the build phase without
the native suite). Every leg sets `COSMIC_CI_CHECKED_SUITE=skip`, and
still builds and verifies its checked core in assemble, which its
fixtures use; a leg that skips the suite removes a `checked.db` from its
verdicts, which would otherwise ride along whole in each save.

- `checked-shard` (`linux-x86_64-checked-shard-<part>`), a share of the
  suite each, four jobs of one matrix, on a full run where the legs run.
  It builds the checked core and the format decoder the contract's
  fixture would have left (`platform checked-build`), and runs its
  share of the suite (`platform checked`, `cosmic test --shard I/N`,
  `COSMIC_CI_CHECKED_SHARD`; as a light run's linux-x86_64 legs split
  their native suite). The harness deals the tests in turn in sorted
  order, so a share is a quarter of them and of the time whatever any
  restored. The share's bound is its own, 600 s
  (`checked_shard_timeout_ns`): the suite's 1096 s where no verdict
  stood and 1504 s at the slowest are 274 and 376 s a share, and the
  job's 25 minutes hold its three minutes' build and that bound with
  room. It restores its verdicts as the whole suite's job did, from
  the entry of the tree's base on main, and in the merge queue takes
  the verdicts of the same part of the run ahead (`queue-ahead`,
  `verdicts-linux-x86_64-checked-shard-<part>`). It trims what it
  restored to the rows its run used, which are its tests', and keeps
  them as that artifact in every event, `checked`'s input. A share
  checks no C function is entered by some test, which only a whole run
  answers; it saves and seeds nothing. Its `operations.db` is kept as
  `ci-driver-linux-x86_64-checked-shard-<part>`.
- `checked` (`linux-x86_64-checked`) gathers them, after all four
  passed (`needs`; a failed share skips it, and `ci` fails on the
  share), except in a run that saves (main's push, the nightly): there it
  runs past a failed share, runs no test, fails, and saves the shares' rows (a
  failed share keeps its own, without the failed test's), so main's newest entry
  no longer holds that test's pass. It builds the checked core again (`COSMIC_CI_CHECKED_SUITE=gather`)
  and merges the four artifacts into a verdict cache that holds
  nothing of main's (its restore only looks the entry up, which the
  save compares with), then runs the whole suite, on which every test
  stands (`stands` takes it for a run that gathers: not `--all`, not `--no-shared`, even where the
  merge queue's change moves the harness and a share ran every test),
  so that what a whole run alone answers is checked, the C functions some
  test enters, which the rows carry. A test that keeps no verdict runs
  again here. The run's bound is 300 s (`checked_gather_timeout_ns`):
  where a share's artifact is missing the whole suite would run, and the
  bound fails the job rather than let it take twenty minutes. Then the
  bounded performance fixture
  (`platform performance-checked`). Its verdicts it keeps under a name of
  its own, `verdicts-linux-x86_64-checked-<host>-<features>-<digest>`,
  trimmed, saved on `COSMIC_CI_SAVES` and seeded as a leg's are; the
  cache entry holds the checked suite's rows alone, where the same job's
  narrowing run kept a `verdicts.db` of another 8700 rows nothing read.
- `checked-narrowing` (`linux-x86_64-checked-narrowing`), the whole
  suite on a checked run (`--check-types`, `platform checked-narrowing`)
  on the release tool, which stands on no verdict and reads no checked
  core: it boots and keeps and saves nothing. A full run only.
- `format` (`linux-x86_64-format`), a light run's format check
  (`platform format`), which a full run makes in linux-aarch64's assemble.
  There it is `fix --check .`; on a light run it lays out only what the
  branch changed since its base on main
  (driver.tl changed-paths, `fix --check --changed`), whose
  tree the queue held to the whole check, and still makes every check
  spanning files -- the tree checks, the links, the asserts -- over the
  whole tree. Where a path changed is part of what
  checks each file alone (the layout, the C rules, the compiler, the
  core), or the paths cannot be named, it checks the whole tree. That
  check takes some seven minutes in a fresh build directory, which holds
  no memo of what the check found in each file (build/check_memo.tl,
  `translate-check.db`). So the job restores the newest memo its ref can
  read, `check-memo-v1-<run>` by its prefix (a branch's restore takes
  main's), `COSMIC_CI_CHECK_MEMO` names it to the phase, which puts it where the
  check reads it and leaves the check's own beside it; and the
  scheduled run, which runs this job too, with no paths changed, checks the whole tree
  and saves what it left. A row is keyed by the file's bytes and the
  check's own sources, so a memo a day old answers for every file the branch
  did not change, and a miss costs only the check's time. A branch saves none, and
  an entry unread for a week is evicted.

On a branch push (`light`), which runs no checked suite, the shares and
the narrowing run do not run, and `checked` runs only the pinned CI
driver's check (`cosmic-driver test cosmic_ci`, 27 to 54 s a leg where
it ran), which a light run's legs skip, and which it skips too where
main's linux-x86_64 leg left its marker for the same key (that leg's
host, named again under the leg's name, and what the key hashes): no
boot, so it ends in a minute or two. Beside it `format` boots and checks the
format, so that the check, which took longer than the legs, is no
part of another job's path.

The jobs restore linux-x86_64's zig build outputs and compiles, which
that leg saves, and save neither. Each keeps its `operations.db`, under
its own name. The `ci` join requires them all, a job a scope does not
run counting as passed, and `report` counts them with the legs. Each
moves its tree to a path of the commit's own, as a leg's does: the checked core
runs the harness, the boot's staging and `tool.tl entry` unsandboxed
at that path, so a path of another length each commit varies what the
sanitizers see. The tree moves back before the seed and the verdicts'
save, whose path actions/cache names relative to the workspace
(below).

A full run's critical path through them, from the queue's runs of
2026-10-23: a share's runner starts, restores, boots and builds the checked
core in 175 to 218 s, runs its quarter of the suite (some 180 s where most
stood, 274 to 376 s where the harness moved and none did) and keeps its
verdicts (10 s), 365 to 408 s or 460 to 604 s; `checked` starts 15 s
after the last share, repeats the 175 to 218 s, merges (5 s), runs the
gathering suite (some 100 s) and the fixture (40 s), and stages its seed
(10 s), 345 to 390 s: 710 to 800 s in all where most stood and 805 to 990 s
where none did, against 1934 to 2326 s of the one job and the legs' 946 to
1503 s. The narrowing run, 150 to 195 s to its boot, its 726 to 861 s and
10 s, takes 890 to 1070 s. So the longest of them ends with the shortest
leg, and the legs are the queue's path.

### the rehearsal job

The rehearsal of the switch (doc/plans/strict-teal.md, "the switch") runs in a job of its own, `rehearsal`
(`linux-x86_64-new-grammar`), on the checked job's host. It is informational until the switch, where it becomes required: it
runs on a full run only, `continue-on-error` marks its failure on the run and no job waits on it, so the `ci` join does not
require it, and the job that cancels a queue run on a failed leg passes over it (ci.yml's `EXEMPT`; build/workflows_test.tl
holds every `continue-on-error` job to both). A branch push shows the job as skipped, one of the exceptions
`build/workflows_test.tl` names. The job restores linux-x86_64's zig build outputs and compiles and saves neither, and runs these phases in order:

1. `boot`: the tree, with the fork's compiler, as every leg boots it: `bin/zig build cores boot -Dboot-cores=all`, the portable tool of every core. A bare `boot` writes a tool of the host's core alone, with a placeholder for each other core, which no leg verifies.
2. `rehearsal-examples`: the examples (`*_example.tl`) and the code blocks of `doc/guides`, which a user copies, each compiled alone
   by the new checker (`build/example_checks_main.tl`, the example part of `COSMIC_GRAMMAR=new cosmic fix --check .`), on the tool
   `boot` built: the check asks for the new checker itself. What they still write in a form only the new grammar reads, or a type
   the new checker lacks, is pinned per file and code under `[examples]` in `build/ceilings.txt`: a finding over its pin and a pin
   above its findings fail the phase, so the pins only fall. Every step after `boot` runs on `boot`'s outcome alone
   (`if: always() && ...`), so a regression in an example fails this step and skips none of the rest.
3. `rehearsal-boot`: the tree again, with `COSMIC_GRAMMAR=new bin/zig build boot -Dboot-cores=all`. The new pipeline (`build/pipeline.tl`) compiles
   it in one process, taking no compile another run made, and the tool it leaves carries the Lua the new generator wrote and
   the declarations of the standard library a project is typed against (`build/checker_declarations.tl`). It records that it was
   built so (its `compiled_by` is not its `compiler`, `reboot.settled_by`), so that a run that asks for the fork's builds it
   again and one that asks for the new checker's does not. The phase fails for a tool that does not say so. A boot holds about
   7 GB of memory at its peak.
4. `rehearsal`: the whole suite on that tool (`cosmic test` with `COSMIC_GRAMMAR=new`), in the verdicts of a file of its own,
   `new-grammar.db`, under a cache name of its own: a verdict of one grammar stands for no run of the other. The suite runs
   without `--bail`, which a queue run adds: the failures are judged over every test. A run that built the tool again is no
   run on the tool the phase booted, and fails.
5. `rehearsal-project`: the two projects of `testdata/rehearsal`, each built and tested outside the tree with the new checker,
   which holds a project to the whole checker, the error-slot rules of `build/contracts.tl` included (the fork holds cosmic's
   own tree alone to them).
   `project` is written in the Teal both checkers read and passes; `fork_only` is written in forms only the fork reads (nil
   given for a type that does not hold it, a function assigned to a path of two dots) and is refused with the new checker's words
   and fix, and with no word of a pin or of `build/ceilings.txt`, which a project has none of. There is no fork to fall back to.
6. `rehearsal-seed`: all of `lang/` translated, compiled with `compile --grammar new`, and its tests run against the Lua
   (`build/lang_proof.tl`); then the same translation compiled by the pinned release (`bin/cosmic-bootstrap`), whose Lua differs
   from the tree's only in the files `lang/SEED_DIFFERS` lists, held both ways as the bridge holds `checker/SEED_DIFFERS`. The
   bridge, `build.zig`'s `seedCompiler` and `checker/SEED_DIFFERS` stay the fork's until the switch.

The run's failures are held to `testdata/gate/rehearsal.txt`, the failures the new checker is expected to have, one
`<failure> -- <reason>` a line: a test (`<module> <test>`), a module the new checker refused (`<file> <code>`, the code of its
first error) or a C function no test entered (`<file>:<function>`). The job fails for a failure the list lacks and for an
entry whose failure did not happen, so the list only shrinks, and is empty at the switch (`ci/cosmic_ci/rehearsal.tl`).

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
version ([`cosmic_ci/host_id.tl`]), which differ between runners of one leg:
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
merge queue restores main's and saves nothing but one thing: a PR's
later pushes stand on main's entries, not its earlier push's. GitHub
searches a ref's own entries before main's, so a branch's entry saved
before only main saved still wins over main's newer one under the same
prefix.

That one thing is a branch's compiles. A change to the compiler (the
Teal compiler's patches, the build's modules a compile
runs: build.identity's `compiler_identity`) moves every compile's key, so
main's entry answers none of a branch that makes one, and each of its
pushes compiled the whole tree again (some 40 s a boot, on each leg and
the checked job). So a branch's push (`light`) whose builds compiled
more than 50 modules its restored entry lacked (`compiles-trim`'s
`fresh`) saves its trimmed compiles under
`compiles-branch-<leg>-<compiler>-<digest>`, where `<compiler>` hashes
the build's own modules but its tests and the Teal
compiler's and Lua's pins and patches: wider than the compiler's
identity, so an edit to the rest of `build/` falls back to main's entry
rather than to one of another compiler. Every restore of the compiles
asks for `compiles-branch-<leg>-<compiler>-` first, then main's
`compiles-<leg>-`; GitHub lets only the ref that saved an entry restore
it (beside the default branch's, which every ref restores), so main,
the merge queue and sibling branches never read a branch's, and on main
the first prefix finds nothing. Each is some 5 MB compressed a leg;
51 of the 130 branch pushes from 2026-09-29 to 2026-10-01 would have
made one, three legs each, and 20 later pushes would have stood on one
rather than compile the tree again. `prune` deletes them a day after
they were saved, so they hold some 600 MB of the repository's 10 GB. The rows are keyed by
their inputs and digest-checked as main's are, so an entry of the wrong
compiler costs only the compiles it misses.
Which entry a restore takes decides only how many tests stand, never
whether a verdict or a compile is right: every row is keyed by its own
inputs.

The verdicts and the compiles are trimmed to the rows the run used
since its start and saved under their prefix and a digest of those
rows, so a run that reached only what it restored names that entry
again and saves nothing new. Saved whole, a leg's verdicts came to about
40 MB compressed a main push, most of it under keys no later run
reaches; trimmed, 8 to 13 MB. Runtime changes and harness epoch bumps
move every verdict key. Other edits move the keys whose declared inputs
or import closures change. The cost: main's saved file holds only its
newest commit's keys, so a branch based on an older main may need verdicts
that were trimmed away. So main also names, under its commit, the
entry each job's verdicts are in, whether it saved it or restored it:
a tiny entry whose key, `<prefix>sha-<commit>-<digest>`, ends in that
entry's digest (`seed` too, from the key `driver.tl queue-stage`
names), saved from a path of its own, so of another version, which the
verdicts' restore by prefix never takes. Each restore asks first for
the entry of the tree's base on main (`driver.tl merge-base`: a
branch's merge base with main, through the API; the merge queue's
base): it looks up `<prefix>sha-<base>-`, which downloads nothing and
takes the newest name, takes the digest from the key found and
restores `<prefix><digest>`, then the newest. So a commit's verdicts
are stored once, by content. ci.yml's `prune` job deletes the
names more than a day old on each push to main
(`driver.tl prune-commit-verdicts`, with the one token in
ci.yml that may write the cache, `actions: write`); a branch based on
an older commit restores main's newest. A cache entry is never
overwritten, so a run of main that failed (the scheduled run's forced
recheck can: it stands on no verdict) saves its rows, less the pass it
took out of its own database, under a new digest and names them under
its commit beside the name its commit's first run saved; but a leg that
stopped before its trim names none. ci.yml's `invalidate` job therefore
deletes the names under that run's commit, every host's, once a run
of main that saves failed (`driver.tl invalidate-commit-verdicts`),
and the restore takes the newest by prefix, which is the failed run's
own save, kept as the failure's evidence. A run that failed keeps what it
restored with what it reached (`whole`). The compiles are saved only
where the native build and suite passed.

zig's caches are restored outside the checkout, at the same path every
run, since zig keys what it compiles by path. There is one entry per
leg, even where two legs share a target: two legs saving one key in
parallel means only one ever wins, and the other restores a cache
another host built. An entry is never replaced under its own key, so
each save takes one of its own:

    zig-build-<leg>-<vendor>-<scope>-<core>-<run>-<attempt>

The platform and checked jobs use `.github/actions/cache-names` before
restoring build caches or moving the checkout. It names the vendor, core and
branch compile inputs, the runner image, and the start time used by
cache trimming; restore/save policy stays with each job in ci.yml.

`vendor` hashes what compiles the vendored libraries (the pin,
`build.zig`, `build/zig.tl`, `vendor/`, `patch/`, the configuration
headers they read from `core/`) but not the trees zig never compiles
(tzdata, cacert, onecrl, wpt-url, html5lib-tokenizer, wpt-html-parsing),
nor the applier, `build/patch.tl`: it names each patched tree by the bytes it writes, so an edit to it that writes the
same trees leaves every vendored object's path, and so zig's cache,
as it was. `core` hashes the core's own C.
`scope` is `full`, where assemble passed; a `light` entry, saved before
only main saved, is still restored last. The restore takes the newest
entry for this vendor part (`full` with this core part, else `full`,
else any); off main, where none has this vendor part, a second step
takes the leg's newest of any, since in one step a ref's own older entry
would win over main's.

Main saves an entry only where assemble passed and it had nothing
`full` for this vendor part, so once per vendor part and leg; a push
that reuses the queue's run builds nothing, and saves instead the
queue's leg's entry where that leg restored none of its core and vendor
part (the queue's result, above), so once per core change too.
The scheduled run restores nothing, compiles cold and saves a compact
entry. zig never prunes its cache, and a save carries all its run
restored, so a day's core changes each saved one that held the last's,
until the nightly's cold build: at a day's end macOS's entry was 561 MB
compressed (1.8 GB on disk) and linux-x86_64's 867 MB, where the
entries of 2026-09-29, before the queue seeded them, were 118 to 142 MB;
and every leg's first step, the restore, took 9 to 19 s on Linux and
15 to 27 s on macOS. So before
either save a leg prunes them (`driver.tl zig-prune`,
[`cosmic_ci/zig_prune.tl`]): a core change makes zig write the manifest
of the step that copies `core/` again, vouching for a new copy, so the
old copy is no manifest's, and every compile and link of the old core,
which lists a file of it, goes with its output. On that day's last
seed that is 1.2 of its 1.8 GB (147 of its 165 linked cores), leaving
some 140 MB compressed; a build of the tree it was built from reads
none of what goes, and one of an older core compiles it again. The
prune keeps everything where a manifest reads otherwise than zig
0.17's, and an orphan holding files no current output holds (zig's
`dependencies.zig`, which `zig build` writes with no manifest).
When
main saved after every run, GitHub evicted the least recently used
entries, the fuzz job's and other legs' own among them, which then
built cold; one a core change is fewer, and the older of them are the
least recently used (the `TODO:` on the queue leg's seed, should they
still crowd out entries in use). The cost: a vendor change's first
main run builds cold (minutes a leg), and a queue run that lands on a
core change not yet on main (the run ahead's) compiles it again,
incrementally. Where assemble fails on the first main run after a vendor change,
nothing is saved, so every main run builds vendor/ cold until one
passes assemble or the nightly saves; a branch stays warm through the
restore of another vendor part.

A run of main or the queue that restored an entry of its own vendor and
core part still grew it by tens of megabytes. Such a run marks the cache
right after the restore and lists, before the prune, the runner's CPU and
what the build wrote since (`.github/scripts/zig-build-writes.sh`, the
step "list what the build wrote to the zig build cache"), for the `TODO:`
on the restore in ci.yml.

actions/cache archives with `tar -C $GITHUB_WORKSPACE` and a path
relative to it (`../../_temp/...`), which names nothing through the
link `place-tree` leaves were the tree more than one directory deep.
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
(`ci/`, `bin/`, the scripts, the driver and cache-names actions, and ci.yml) and the
leg's host; an exact hit skips the check, except on the scheduled and
manual runs. The host is in the key, since the check runs unsandboxed
and its tests start the host's own programs (`/bin/sh`, `cp`): a marker
says the driver passed on that host. On a Linux leg those programs are
the container's, so the host is the container (`COSMIC_HOST_ID`'s hash:
its image by digest, how it is started and the engine's version), not
the runner's image, which GitHub rolls out over days: with
`ImageVersion` in the key, a queue leg on the other image of a mixed
fleet missed main's marker and checked again (3 of 12 queue runs on
2026-09-30, 53 s each on the gating leg). Keyed by the container,
a leg on either image of a mixed fleet finds the marker only while
both ship the same engine: its
`Server.Version` is in `COSMIC_HOST_ID`, so an image that moves the
engine (a moby bump) still misses main's marker until main saves
again. What the runner's image
still gives a Linux leg, its kernel and the engine, reaches the check
only through the engine (keyed) and the kernel's system calls, which
the check's tests (processes, files) use as any Linux does; the
scheduled run checks on every leg whatever was saved. The macOS leg
runs on the runner's own userland, so its key holds the runner's image
(`ImageVersion`), and an image rollout misses its marker until main
saves again. So a full run checks on each leg where its key moved. A branch
push checks only in the checked job, on linux-x86_64's host. It looks
up main's marker and skips the check on an exact hit, but saves no marker
of its own. Before anything lands, some trusted run has checked each key: main's earlier marker, the queue run ahead's, or the queue run's own check. Main saves
a marker only once its commit lands, so the queue runs behind a change to
what the key hashes would all check again: a queue leg that finds no
marker looks for the run ahead's, as it does the verdicts (`driver-ahead`
steps), and skips the check where that run's leg kept the same key as
`driver-checked-<leg>` after a check that passed, a marker found or one
taken. It waits only 30 s, and not at all for a leg ahead that has not
begun its boot (which follows its check), so queue entries that start
together still each check; the artifact is not main's marker, which `seed` saves
from the run's staged `driver-checked/` as before.

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
[`cosmic_ci/github_api.tl`]: cosmic_ci/github_api.tl
[`cosmic_ci/github_api_test.tl`]: cosmic_ci/github_api_test.tl
[`cosmic_ci/report_test.tl`]: cosmic_ci/report_test.tl
[`cosmic_ci/suite_output.tl`]: cosmic_ci/suite_output.tl
[`cosmic_ci/zig_prune.tl`]: cosmic_ci/zig_prune.tl

[`cosmic_ci/host_id.tl`]: cosmic_ci/host_id.tl
[`Runner.phase`]: cosmic_ci/runner.tl
