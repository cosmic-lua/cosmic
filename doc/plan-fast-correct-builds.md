# plan: fast, correct builds and tests

This is the working plan for building and testing only what a change
implicates, locally and in CI, with the cache relied on and the sandbox
enforcing it. The work runs in five stages, in order. Each stage ends
at a milestone that a run's own output decides, without reading any
code (see "Milestones" for the definitions). Within a stage, items are
listed in the order to do them. Each item says:

- what it changes
- what it waits on
- what shows it worked

Landed work is listed at the end for the record, and leaves this file
once the plan closes. Work with no plan yet goes in
[roadmap.md](roadmap.md).

The rule every item serves: a test's verdict is keyed by the digest of
its declared inputs (`Test.needs`, its import closure, the core, the
host), and the sandbox holds the worker to those inputs. A verdict that
stands wrongly is silent. So each step that leans on the cache more
waits for the alarm, and for the soundness fixes that make that step
safe.

## Where it stands (main at 13922ff, 2026-09-28)

The milestones move these numbers. Each milestone measures them again.

### CI

- **Gating run** (`merge_group`): 11 to 16 min wall.
  - linux-x86_64 takes about 13.5 min; the other legs take about 8.
  - linux-x86_64's `assemble` step (checked core and checked suite)
    takes 5.5 to 6 min. Its suite stood on 0 verdicts in every run
    (orchestration.tl's `TODO:`).
- **Main push:** the full scope again, on the SHA the queue just passed.
  - 10 to 15 min wall.
  - About 70 runner-minutes per landed change, queue and main together
    (37 + 35 in runs 36369832830 and 36370736026).
- **Branch push** (light scope): 2 to 4.5 min, with no breakdown by
  step yet (0.4 records one).
- **CI-only commit** (9022243): linux-x86_64's native suite took 25 s
  and its portable suite 17 s, both standing. When the key moved, they
  took 2 min and 1.6 min.
- The key moved in 27 of the 50 commits before 90056d6. Each of those
  touched `build/test.tl`, which every key holds by its source, or the
  closure of the key's own code.

### Local

Measured on 4 cores, sandboxed, with 1988 tests.

- Cold boot: 2 min 54 s. Cold suite: 82 to 88 s.
- Nothing changed: 2.3 s, with every test standing.
- Fresh worktree: boot 6 s, suite 13 s. Every test stands on another
  checkout's verdict.

A comment appended to one file reruns:

- A test file: 155 tests, 10 s.
- `cosmic/shape.tl`: 582 tests, 56 s. That is about 542 keyed by the
  whole program or projection (`tool`/`store`) and about 40 that import
  it.
- `cosmic/codec.tl`: every test, 97 s. That is by design: every worker
  loads it (`build/test_worker.tl`'s `worker.loads`), as it does
  `cosmic.fs`, `cosmic.hash` and `cosmic.sqlite`.
- `build/test.tl`, `build/zig.tl` and `cosmic/http.tl`: every test. No
  worker runs these; the key holds them anyway (item 2.2).

## Stage 0: the alarm, the key's guards, the numbers (days)

These items are cheap and mostly independent. Every later stage
leans on them.

### 0.1 Report a red scheduled run, and pull its verdict

Only the scheduled `--all` run catches a pass that a key does not
answer for: the clock, a flaky test, a missed input. Today it tells
only whoever last edited the cron line (the `TODO:` on ci.yml's
`schedule`), and fuzz.yml's nightly run is the same.

Worse, a red run leaves the wrong pass standing, in every leg's saved
cache and in each developer's `~/.cache`.

- Change: a final job in ci.yml and fuzz.yml.
  - It runs on `schedule`, and on a push to main for as long as main
    still runs the full scope (1.2 ends that).
  - On failure, it opens an issue with a stable label, or comments on
    the open one, naming the run and its failing tests. It needs
    `issues: write` on that job alone.
  - The failing leg saves its verdict cache with each failed test's
    rows deleted, under a key newer than any before it. The next run
    of every branch then reruns those tests.
- Waits on: nothing.
- Shows: a `workflow_dispatch` input that forces one named test to fail
  opens the issue. The next run of main reruns that test. A scheduled
  run cannot be tried off the default branch, so the dispatch input is
  the test.

### 0.2 Guard what shapes a key

`build.declared_key` and `build.shared_verdicts` are held by their
source, so an edit to them moves every key. The hand-bumped
`version = "declared-3"` covers what no key holds by its code:
`build.importer`'s graph key, and the closure store's address. Two
failures are not caught today:

- A new field of a spec that the key leaves out.
- An encoding that maps two specs to one preimage.

2.2 moves more key-shaping code out of the source-held set, which makes
this guard a prerequisite for it.

- Change, `declared_key_test.tl`:
  - Build a fully populated spec, then change every field in turn,
    enumerated from the record's catalog entry. The key must move
    each time, so a field added and left out of the key fails.
  - Add a fuzz property: distinct specs give distinct preimages
    (compare the strings, not the hashes).
- Change, fixed tree: pin the graph key and the closure-store address
  over a fixed tree, with a failure message that says to bump
  `version`.
- `version` stays.
- Waits on: nothing.
- Shows:
  - A trial edit that leaves one field out of the key fails the test.
  - A trial edit to the graph key's encoding fails the pin.

### 0.3 Two `cosmic test` runs in one checkout

A review run saw two concurrent `cosmic test` invocations in one
checkout end in `the tool's database was built by other code than its
own` and then `disk I/O error`. One run was rebuilding the tool while
the other read `o/build.db`. An editor, a watcher and a terminal can
all hit this.

- Change: add a note to AGENTS.md now, to run one at a time.
- Change: a test that starts two runs against a stale tool. Each must
  pass, wait, or refuse with a message naming the other run. Then fix
  it, likely with a lock around the self-rebuild.
- Waits on: nothing.
- Shows: the test.

### 0.4 Emit the numbers every milestone reads

`driver.tl summarize` records each operation's phase and time. It
records no suite tallies and no digests, so today a milestone rests on
scraping logs.

- Change: every suite, fixtures included, writes one row to the
  operations database and the step summary: `suite`, `ran`, `stood`,
  `elapsed_ms`, the core digest, the harness digest, and whether each
  matched the restored cache's. The operations database is already
  uploaded as `ci-driver-<leg>`.
- Change: a `cosmic_ci` verb, `report --runs N`, fetches those
  artifacts and each job's step times (`gh api
  repos/cosmic-lua/cosmic/actions/runs/<id>/jobs`). It prints each
  milestone's figures, and whether each run qualifies.
- Change: record a step-time baseline for light (branch) runs, on all
  four legs.
- Waits on: nothing.
- Shows: `report --runs 10` prints this file's "Where it stands" CI
  numbers.

### 0.5 Refuse the retained artifact descriptor

A portable start keeps a descriptor on the artifact
(`COSMIC_PORTABLE_ARTIFACT_FD`). Through it, a test can read every
module the program carries, past the worker's hold on the store and
past every key (the `TODO:` in `core/syscalls_fs.c`). Stages 1 and 2
lean on keys this hole defeats, and batch 2 of the tool/store floor
(2.4) moves hundreds of tests onto that path. `cosmic_store_artifact`
already exists (`core/store.h`), so the fix is not blocked.

- Change: one choke point, `cosmic_checkfd`, refuses that descriptor.
  A rule in `build/c/rules.tl` requires every binding that takes a
  descriptor to call it. That covers `read`, `pread`, `lseek`, `fstat`,
  `dup`, `dup2`, `fcntl`, `fchdir`, `openat`'s dirfd, `fd_flags`, and
  `spawn`'s descriptor map and standard streams (including inheritance
  by default). It also covers an open of `/proc/self/fd/<it>` or
  `/dev/fd/<it>`.
- Check the program's own path and `/proc/self/exe`. A worker that is
  not `tool` must not reach the embedded database through them either.
- Waits on: nothing.
- Shows: a test for each binding, generated from `core/syscalls.h`,
  tries the descriptor and is refused, on the checked core too.

### Milestone M0

- A forced failure opens the issue and pulls the verdict.
- `declared_key_test` fails on an omitted field.
- The concurrent-run case is a test.
- `report` prints the baseline.
- The artifact descriptor is refused.

## Stage 1: the gating run's critical path (about a week)

### 1.1 Checked suite stands (branch `checked-core-stable`)

The checked suite stands on nothing, because the checked core's bytes
name the run. Each object's `DW_AT_comp_dir` is the tree root of
whichever build first compiled it, since zig's object cache keeps old
paths. The generated `coverage_map.c` is named by its zig-cache output
directory, which is new on every relink.

- Change, `build.zig`: add `-fdebug-compilation-dir=.` to every C flag
  set (own C, the coverage map, each vendored library), and `-g0` to
  the generated map.
- Change, musl: zig 0.16 builds its bundled musl itself, and
  `build.zig` has no hook for its flags. CI compiles it after the tree
  moves to a per-commit path, so its comp_dir is whichever run saved
  the restored zig entry, which moves at least daily. In order of
  preference:
  - (a) Key the checked runtime by the core with its debug sections
    left out: the hash of a `--strip-debug` copy. This is one key
    change.
  - (b) Rewrite the comp_dir strings after linking.
  - (c) Accept a daily cold run, with a `TODO:` that says so.
- Change, `ci/cosmic_ci/orchestration.tl`:
  - Assert that the digest the key uses names no run: search for the
    bare root path, leaving out the project cache's prefix under
    `ci/run-local`.
  - The suite writes `checked.db` beside the leg's `verdicts.db`.
  - The suite runs `cosmic test --census`.
- Waits on: 0.4, to show it.
- Shows: the next gating run after a main push, on a commit whose core
  and harness digests match the restored ones, has a `checked` row
  standing on at least 90% of its tests. The suite's share of
  `assemble` falls from about 5 min to under 40 s. The rest of
  `assemble`, building and linking the checked core, is measured, not
  targeted.

### 1.2 Store.meta held

A worker's `Store.meta` reads are not held (`build/test_worker.tl`'s
`TODO:`). Outside the `compiler_readers` allowlist, a meta key that a
module reads is neither refused nor keyed. This is here, before stage
2, because 2.2 ends the frequent full reruns that hide such a gap
today, and 2.4 moves tests off `store` onto `hold_store`.

- Change: `hold_store` holds `Store.meta` to the keys a test's closure
  may read, and the key holds each meta row it allows.
- Waits on: nothing.
- Shows: a test module that reads an unlisted meta key fails, and
  names the declaration that would allow it.

### 1.3 Main stops re-running the queue's SHA

Today every change runs the full scope twice. Main repeats the queue's
run for two reasons:

- A `merge_group` run saves no cache (every save in ci.yml has
  `github.event_name != 'merge_group'`), and its ref's caches cannot be
  read from main.
- `prerelease.yml` takes its products from the main run.

Main's run is also the only second execution of a change, on another
runner. That second run catches some flaky and clock-dependent passes.
After this item, the only safety net is the nightly `--all` run and
0.1's pull.

- Change, queue run: upload each leg's trimmed `verdicts.db`,
  `portable.db`, `checked.db` and compiles database as artifacts. They
  are 8 to 13 MB.
- Change, main push: a first job finds the successful `merge_group` run
  of ci.yml for `github.sha`, polling while it finishes. If there is
  one, and the commit moves no vendor part:
  - Each leg downloads those databases by run id and saves them under
    main's keys, the way the queue run would have. This needs
    `actions: read`.
  - Every phase is skipped.
  - A trim is not needed, since the queue already trimmed. A
    boot-and-native-suite trim would drop the portable and checked
    rows and assemble's compiles.
- Change, otherwise: a commit that moves a vendor part runs the full
  scope, so the `full` zig entry is saved.
- Change, prerelease:
  - `prerelease.yml` resolves the queue run id. It already has
    `actions: read`.
  - Loosen its `event == 'push'` gate.
  - Take the products from that run.
  - `SOURCE_RUN_URL` names the queue run. `prerelease.tl` checks the
    lanes' bytes as data, so products from another run pass it.
  - The `ci` job's provenance step points at the queue run.
- Waits on: 1.1, since the checked verdicts reach later queue runs only
  through main's saves; and 0.1.
- Shows: a main push whose SHA passed the queue finishes in under 3
  min. Its prerelease names the queue run. The next gating run stands
  as it would have without this item.

### Milestone M1

- The median gating run is under 9 min, over the ten gating runs whose
  core and harness digests match the restored ones (see Milestones).
- On those runs, the checked suite stands on at least 90% of its tests.
- A main push after a green queue run takes under 3 min.
- Runner-minutes per landed change fall from about 70 to under 40.

## Stage 2: an edit reruns what it implicates (two weeks)

### 2.1 Observation removal, PR 1 (#2285)

The sandbox and process helpers leave the observation log's module:

- `build.confine` takes the spawn stand-in as `enter`, plus
  `confine`/`must_confine`, `forbid_running`, `worker_unveil`,
  `itself`, `held_to_sandbox` and a Teal `resolution`.
- `build.this_program` takes `program` and `environment`.
- `key_part` and `tree_name` move into `build.declared_key`.

Behavior is identical. It comes first because it moves
`declared_key`'s own requires, which 2.2 then cuts.

### 2.2 Narrow what the key's own code holds

Every sandboxed key holds three things:

- the harness: what a worker loads, plus `harness_own`
- `build.test` by its source
- the import closure of `build.declared_key` and
  `build.shared_verdicts` (`key_code`, `build/test.tl`)

That closure is 38 modules. It reaches through
`build.filesystem_observations`, `build.test_inputs` and
`build.caches` to `build.zig`, `cosmic.http`, the archive modules and,
through `local type` requires, `build.ast.*`. So an edit to any of
these reruns every test, even though no worker runs them. Edits to
`build/test.tl`'s scheduling and reporting code rerun every test too.

- Change, in PRs, each moving the probes below:
  - (a) Cut `declared_key`'s requires of the observation log and
    `test_inputs`. Move the cache-locating variables into
    `build.cache_names`, as `build/test_inputs.tl`'s `TODO:` asks.
  - (b) Leave `local type` edges out of the `key_code` walk. Teal
    erases them, and `declared_key.tl` already argues the point for
    the harness.
  - (c) Build what a worker is given (`tree_names`, `declared_names`,
    its timeout, its sandbox plan) as one serialized record in a small
    held module, and key that record as data. This closes the unkeyed
    timeout (`build/test.tl`'s `TODO:`). The sandbox plan's part waits
    on `held` and the cache binds naming no host location (the same
    file's `TODO:`).
  - (d) Only then take `build.test` itself out of the source-held set.
    Its spec assembly moves into the held module.
- A test pins the held set's closure, as
  `build/compiler_readers_test.tl` does for the compiler's.
- Waits on: 0.2, which guards what leaves the source-held set, and
  1.2.
- Shows: a comment in `build/zig.tl`, `cosmic/http.tl` or
  `build/test.tl`'s reporting code reruns only the tool/store floor and
  the importers, not every test. A comment in `cosmic/codec.tl` still
  reruns every test, by design.

### 2.3 The checked job split, if still needed

- Decision: with 0.4's `report`, count the last 20 gating runs in which
  linux-x86_64 exceeds the next-slowest leg by more than 2 min. Split
  only if that is more than a quarter of them.
- Change, if split: a `checked-linux-x86_64` job runs a new `platform
  checked-suite` phase:
  - a boot without the local suite, `bin/zig build sanitized`, and the
    suite
  - it restores the leg's caches without saving them, and keeps
    `checked.db` under its own prefix
  - `COSMIC_CI_CHECKED_SUITE=skip` on every leg; `assemble` still
    verifies the core
  - the `ci` job needs `[platform, checked]`; the new job is not a
    matrix entry, since `job-total` feeds attestation
- Waits on: 2.2, which changes how many commits are cold.

### 2.4 Tool and store floor, batch 2

Batch 1 (#2283) took 245 tests off `tool`/`store`. Batch 2 takes the
modules with 3 or more tests to move, each split into
`<module>_tool_test.tl` or `<module>_store_test.tl`:

- `core/syscalls_test` (65 of 80)
- `build/filesystem_observations_test` (30 of 44)
- `cosmic/child_test`
- the sandbox tests
- about 15 smaller modules

- Waits on: 0.5 and 1.2. A test moved off `tool` is still exposed to
  the artifact descriptor, and one moved off `store` to `Store.meta`.
- Shows: the floor, counted by a named `o/bin/cosmic sql` query over
  the catalog's `tool` and `store` declarations, is about 355 (about
  542 today).

### 2.5 Stand-in built once per run

`build/stand_in.tl` builds a whole tree with `embed.tree`, in a child,
for every test that needs one. That costs about 1 s on the release
core and 3 s on the checked core, for about 40 tests: 31 s of release
test time and 100 s of checked. Workers are one process per test, so
no in-process memo helps.

- Change: `stand_in.build` compiles only `cmd/probe/main.tl` against
  the carried modules. This frees 62 tests from `tool`.
- Failing that, the runner builds the stand-in once under `o/`, and
  tests declare it as `tool` tests declare the program.
- Waits on: `build.embed` taking a prebuilt store (the `TODO:` in
  `stand_in.build`, a PR of its own), and 0.5.
- Shows: the checked suite, cold, runs about 100 s shorter.

### 2.6 Key precision, smaller

- Writer identity, which is over-wide today (`build/work.tl`'s
  `TODO:`):
  - Change: roots for what a projection depends on, plus a guard like
    the compiler's.
  - Shows: an edit to a writer-only module moves no module's key.
- The settle when one commit moves both the fingerprint's definition
  and the compiler identity's (`build/reboot.tl`'s `TODO:`):
  - Shows: a test commit that moves both boots once.

### Milestone M2

These use the local probes (see Measuring):

- The tool/store floor is at most 355.
- A comment in `cosmic/shape.tl` reruns at most 400 tests (582 today).
- A comment in `build/zig.tl` or `cosmic/http.tl` reruns at most 400.
  Each reruns every test today.
- Over the ten gating runs after M2, whatever their digests, the median
  run's checked suite stands on at least 70% of its tests.

## Stage 3: soundness, before declared keys widen (one to two weeks)

Stage 4 turns declared keys on for every unsandboxed run and deletes
the observed path. So each gap that lets a verdict stand when a rerun
would fail is closed first, or owned by a named item.

### 3.1 Holes with a `TODO:`

- `build/declared_key.tl`: a host directory is keyed by its name alone.
  Key it by a walk, or by a recorded digest.
- `build/test.tl`: a `tool` worker is not held, and may run a stale
  program.
- `build/test.tl`: a stat's time, inode or owner fields, read without
  declaring them, stand on a sibling checkout's verdict. This holds
  under the sandbox too.
- `core/syscalls_fs.c`: `access()`'s answer depends on ids, mount flags
  and ACLs that no key holds.
- `build/test_sandbox.tl`: the program is bound at its host path, so
  the checkout's location reaches the worker.
- `build/test.tl`: paths given to a confined process are not held to
  the effective inputs.
- `core/store.c`: raw tables, and a handle on a database attached while
  a hold is up. They close with 4.2's PR 5. Until then, 1.2's hold
  covers what it can, and this item owns the rest.
- IPv6 in a new network namespace is unkeyed (`build/declared_key.tl`).
- A file under `/usr` changed outside a package goes uncaught by
  `system_identity`.
- `/proc/self/mountinfo` names each bind's host source
  (`build/test_sandbox.tl`).
- `cosmic.removed`, and a module's file, are not in the local compile
  key (`build/work.tl`, `build/importer.tl`).
- `eval/` and `test/portable` are carried but are not tool trees
  (#2258).

Out of scope here:

- `build/test.tl`'s in-tree read through a link that leads out. It is
  on the observed path only, and dies with 4.2's PR 4.
- `build/test_worker.tl`'s standard library outside the closure in a
  project tree. It matters only for releases.

### 3.2 Platform-only code on macOS

The rule lets macOS key its runs without enforcing them, because the
Linux legs hold the same tests sandboxed. That is not true of a darwin
branch. Most darwin branches are C (`__APPLE__` in seven `core/*.c`
files), which the catalog does not see.

- Decision: the macOS leg's scheduled run stays `--all`, and 0.1's pull
  is the backstop.
- Change: add a hand-maintained list of test modules that exercise a
  darwin branch, with a test that the list's modules exist. The macOS
  leg's gating run stands on nothing for those.
- Before 4.2's PR 3, the unenforced worker gets:
  - the tree at a fixed path, or a key that holds the path
    (`build/test.tl`'s `launch`, `TODO:`)
  - its closure store rather than the whole projection (`TODO:` in
    `launch`; waits on `cosmic test --worker` taking `--store`)
- Shows: the list exists and is held by its test. A macOS gating run's
  row shows those modules ran.

### Milestone M3

- Every item in 3.1 has either landed, with a test that tries the
  hole, or has a named owner item and date.
- 3.2's list is in place.
- 3.2's two worker changes have landed.

## Stage 4: fewer paths, less code (two to three weeks)

### 4.1 Fixtures sandboxed, sharing verdicts (branch `fixtures-sandboxed`)

Each fixture declares what it reads with `Test.needs`, naming host
paths by the variable that holds them (`$COSMIC_FIXTURE_PRODUCT`,
#2279).

- The runtime directory gets copies of `tool.tl`'s closure and the
  focused-embed build, with cores made executable at setup.
- The driver unpacks `work/portable-source.tar` as
  `COSMIC_FIXTURE_SOURCE`.
- Inner `cosmic test` runs get `COSMIC_TEST_SANDBOX=0`.
- `format` stays an unsandboxed setup step.
- The launcher's noexec case moves to an unsandboxed module of its own,
  with a `TODO:`.
- `Orchestration.fixture` writes `fixtures.db` beside `verdicts.db`.
- The fixtures' 33-module project is compiled once per leg, not once
  per fixture (2.2 s each).
- The same PR moves `ci/cosmic-driver.pin`. Its design note goes in the
  PR description, not session scratch.

- Waits on: stage 3, and a prerelease carrying #2279. After 1.3, that
  prerelease comes from a queue run.
- Shows: runtime, launcher, identity and product stand on a commit that
  moves neither the product nor the fixtures, taking 25 to 40 s a leg
  (about 2 min today).

### 4.2 Observation removal, PRs 2 to 5

- PR 2: `--audit` from the sandbox's refusals. A sandboxed failure
  names the path the sandbox refused, and the runner suggests the
  declaration.
- PR 3: declared keys become the default for every unsandboxed run,
  retiring `COSMIC_TEST_KEY`. Such a run shares only when
  `COSMIC_VERDICT_CACHE` names a file, and never through the home
  cache.
  - Waits on: PR 2, 4.1, M3, and 3.2's two worker changes.
- PR 4: delete the observed key path, the `reads` column of `runs`,
  `Test.needs.processes` and the worker's logging. That is about 2,500
  lines of Teal.
- PR 5: delete `core/observed.c`, its 29 syscall hooks, the observed
  SQLite VFS, and `core/store.c`'s observe knobs. That is about 1,900
  lines of C and 65 C functions.
- Measure before PR 4 and after PR 5, with the local recipe:
  - ran, stood and elapsed
  - the checked suite's time
  - the core's size
  - the C function count
  - the size of `o/build.db`

### 4.3 One cache verb in CI

ci.yml has three copies of the same sequence: look up the newest
entry, check whether a descendant saved it, save. One copy each covers
verdicts, compiles and the driver-check marker. The SQLite
open/WAL/corruption/set-aside code also has three copies:
`build/shared_compiles.tl`, `build/shared_verdicts.tl` and
`ci/cosmic_ci/cache_trim.tl`.

- Change: a local composite action, with the decision in a driver verb
  tested in `orchestration_test.tl`. `save-unless-descendant.sh` folds
  into that verb.
- Change: one module holds the shared SQLite code. `cache_trim.tl`
  calls the tools' own trim verb.
- Change: the driver-check marker is no longer keyed by event.
- Waits on: M2. This item is maintainability, not speed.
- Shows: at least 10 fewer steps per Linux leg (47 today), and the
  cache decisions have a driver test.

### Milestone M4

- `COSMIC_TEST_KEY`, the observed path and `core/observed.c` are gone,
  with their line counts in the PR descriptions.
- The fixtures' rows show them standing on the median gating run.
- ci.yml's cache handling is one action plus one driver verb.

## Milestones

Each milestone is decided from 0.4's `report`, as follows.

- **A gating run's time:** the slowest `platform` job's
  `started_at`..`completed_at`, which leaves out queueing. The figure
  is the median over the stated runs, with at most two of them over.
- **A qualifying gating run:** one whose suite rows say its core and
  harness digests matched the restored cache's.
- **Stands on n%:** `stood / (ran + stood)` from that suite's row.
- **Runner-minutes per landed change:** the sum of the queue run's and
  the main push's job durations, as a median over 10 merged PRs.
- **Local probe counts:** the `ran` count is the gate. Elapsed time is
  recorded, but decides nothing.

## Measuring locally

- **Host:** a Linux host, sandboxed, with its CPU model recorded,
  checked out at the milestone's commit.
- **Caches:** the build cache and zig caches are warm and left unset
  (`COSMIC_BUILD_CACHE` unset). A cold run means an empty
  `XDG_CACHE_HOME`, and it is labelled so.
- **Verdicts:** every run uses `COSMIC_VERDICT_CACHE=0`, so a probe
  cannot stand on another checkout's or an earlier milestone's run of
  the same edit.
- **Probes:** before each probe, a run shows 0 ran. The probe appends
  `-- probe <sha> <time>` to one file, runs, then reverts. The files
  are `cosmic/shape.tl`, `build/zig.tl`, `cosmic/http.tl`,
  `cosmic/codec.tl`, `build/test.tl` and one test file.
- **Record:** ran, stood and elapsed for each probe.

## Dropped or deferred

- **Portable suite narrowed** to the tests that depend on the artifact:
  deferred. It stands when its key holds (17 s a leg). Revisit if,
  after 2.2, its key still moves on more than 20% of commits.
- **Fixtures run concurrently** within a leg: deferred until after
  M4. Once the fixtures stand, what remains contends for 4 cores.
- **To roadmap.md:**
  - Local eviction of the zig caches: about 720 MB after one boot,
    already covered by AGENTS.md's advice.
  - The analyzer named by what a parse runs (`build/importer.tl`'s
    `TODO:`): it moves every parse key once, for no stated gain.
  - Verdicts shared across runners of a leg, once `system_identity`
    names what a package database does not (orchestration.tl's
    `TODO:`).
  - The macOS groups, `SystemVersion.plist` and a developer's Mac
    beyond the sealed volume. Each has a `TODO:`.

## Landed (this effort)

- **Shared compiles and parses** across checkouts (#2259, #2268). CI
  restores and saves them per leg (#2261). A fresh boot fell from 31 s
  of CPU to 7 s.
- **Harness and closure-store keys:** the harness is keyed by what a
  worker loads (#2262, #2266), the key's own code by its plain bytecode
  (#2265), and closure stores are salted by the writer's closure
  (#2271, #2273).
- **Compiler identity** by what shapes a compile (#2278).
- **The `system` declaration**, and five batches taking tests off the
  host's package identity (#2257, #2260, #2263, #2264, #2269, #2274).
- **Verdict caches:** saved unless a descendant's save is newest
  (#2275), trimmed to a leg's run (#2270), and bounded (#2272's
  follow-ups).
- **`COSMIC_SANDBOX=must`** on every Linux leg (#2276).
- **`Test.needs` host paths** named by a variable (#2279), and the
  driver pin moved (#2277).
- **macOS:** declared keys without a sandbox, and the macOS host
  identity (#2280). The macOS leg now stands on them (#2282).
- **Fixed-point regression** on one gating leg (#2281).
- **Tool and store floor, batch 1:** 245 tests off (#2283).
- **Checked suite bound** at twice its measured time (#2272).
