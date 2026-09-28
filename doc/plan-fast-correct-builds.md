# plan: fast, correct builds and tests

Working plan for building and testing only what a change implicates,
with the cache relied on and the sandbox enforcing it, locally and in CI.
Work is in four stages, in order. Each stage ends at a milestone that a
run's own output shows, with no code read. Within a stage, items are in
the order to do them. Each item names what it changes, what it waits
on, and what shows it worked. Landed work is listed at the end for the
record, and leaves this file once the plan closes. Work with no plan yet
goes in [roadmap.md](roadmap.md).

The rule every item serves: a test's verdict is keyed by the digest of
its declared inputs (`Test.needs`, its import closure, the core, the
host), and the sandbox holds the worker to those inputs. A verdict that
stands wrongly is silent, so the stages put the alarm and the soundness
work before each step that relies on the cache more.

## Where it stands (main at 13922ff, 2026-09-28)

These are the numbers the milestones move. Each is measured again at
every milestone.

- Gating run, meaning the merge queue's `merge_group` run: 11 to 16 min
  wall. linux-x86_64 takes about 13.5 min, and the other legs about 8.
  Its `assemble` step (checked core and checked suite) takes 5.5 to 6
  min, and the suite stood on 0 verdicts in every run
  (orchestration.tl's `TODO:`).
- Main push: the full scope again, on the SHA the queue just passed.
  That is 10 to 15 min wall, about 50 runner-minutes, for every change.
- Branch push (light): 2 to 4.5 min.
- CI-only commit (9022243): linux-x86_64's native suite takes 25 s and
  its portable suite 17 s, both standing, against 2 min and 1.6 min
  when the key moved. The key moved in 27 of the 50 commits before
  90056d6, because each touched the runner or the key's code.
- Local, 4 cores, sandboxed, 1988 tests:
  - Cold boot: 2 m 54 s. Cold suite: 82 to 88 s.
  - Nothing changed: 2.3 s, with every test standing.
  - Fresh worktree: boot 6 s. The suite takes 13 s, every test standing
    on another checkout's verdict.
  - A comment in a test file reruns 155 tests (10 s).
  - A comment in `cosmic/shape.tl` reruns 582 (56 s).
  - A comment in `cosmic/codec.tl` reruns every test (97 s). The reason:
    `build.test` requires `cosmic.hash`, which requires `cosmic.codec`,
    and the runner's whole import closure is in every key (item 2.1).

## Stage 0: the alarm and the key's own guard (days)

These are cheap and independent. They come first because every later
stage relies on the cache more, and today nothing reports a verdict
that stood wrongly.

### 0.1 Report a red scheduled or main run

Only the scheduled `--all` run catches a pass that a key does not
answer for (the clock, a flaky test, a missed input). GitHub tells only
whoever last edited its cron line (the `TODO:` on ci.yml's `schedule`),
and fuzz.yml's nightly failure goes the same way.

- Change: a final job in ci.yml and fuzz.yml, run on `schedule` and on
  a push to main. On failure it opens an issue, or comments on the open
  one, with a stable label, naming the run and its failing checks. It
  needs `issues: write` on that job alone.
- Shows: a deliberately red scheduled run on a test branch opens the
  issue, and a green one leaves it alone.

### 0.2 Pin the key's outputs, retire the hand-bumped version

`build/declared_key.tl` salts every key with `version = "declared-3"`.
A change to how a key is computed that forgets to bump it keeps old
verdicts under the new code, in `o/build.db` and in every checkout's
shared cache.

- Change: `declared_key_test.tl` computes the key of a few fixed specs,
  one per part (closure, needs, host, system, runtime, harness), and
  compares them with digests written in the test. A change that moves
  them fails until the digests and `version` are updated together. The
  failure message says to bump `version`.
- Shows: a trial edit to a part's encoding fails the test.

### 0.3 Reproduce two `cosmic test` runs in one checkout

A review run saw two concurrent `cosmic test` invocations in one
checkout end in `the tool's database was built by other code than its
own` and then `disk I/O error`: one rebuilt the tool while the other
read `o/build.db`. An editor, a watcher and a terminal can meet this.

- Change: a test that starts two runs against a stale tool and asserts
  each passes, or waits, or refuses with a message that names the other
  run. Then the fix, likely a lock around the self-rebuild.
- Shows: the test. Until it lands, AGENTS.md says to run one at a time.

### Milestone M0

- A red scheduled run opens an issue.
- `declared_key_test` pins the key's digests.
- The concurrent-run case is a test, fixed or refused by name.

## Stage 1: the gating run's critical path (about a week)

### 1.1 Checked core byte-stable (branch `checked-core-stable`)

The checked suite stands on nothing because the checked core's bytes
name the run. Each object's `DW_AT_comp_dir` is the tree root of
whichever build first compiled it, because zig's object cache keeps old
paths. The generated `coverage_map.c` is named by its zig-cache output
directory, which is new on every relink. The stripped release cores
have neither.

- Change, `build.zig`: `-fdebug-compilation-dir=.` on every C flag set
  (own C, the coverage map, every vendored library), and `-g0` on the
  generated map.
- Change, musl: it is built in zig's global cache without those flags,
  so it keeps the comp_dir of whichever checkout built it first. The
  digest is then stable only while CI's restored zig cache is the same
  one, and a miss makes the suite cold again. Pass the flag to musl's
  build too, or strip the checked core's debug paths after linking; do
  not settle for a `TODO:`.
- Change, `ci/cosmic_ci/orchestration.tl`:
  - Assert that the checked core names no comp_dir but `.`, and no
    cache path of `coverage_map.c`. Search for the bare root path, and
    leave out the project cache's prefix under `ci/run-local`.
  - The suite writes `checked.db` beside the leg's `verdicts.db`, and
    runs with `cosmic test --census`.
- Shows: `checked suite: ... stood` on a second main run after a commit
  that moves neither the core nor the runner. The `assemble` step goes
  from 5.5 to 6 min to under 1.5 min.

### 1.2 Main stops re-running the queue's SHA

Every change runs the full scope twice. The main push repeats the
queue's run because a `merge_group` run's caches are scoped to its
`gh-readonly-queue/` ref, which no other ref can read, and because
`prerelease.yml` takes its products from the main run.

- Change: on a push to main, a first job asks whether a successful
  `merge_group` run of ci.yml exists for `github.sha`. If one does, the
  legs skip every phase but the steps that restore, trim and save the
  caches. Those still run, so main keeps writing the entries every
  branch reads, but they rebuild only what the saves need: the zig
  build cache and the compiles come from a boot, and the verdicts from
  a standing `cosmic test`. `prerelease.yml` takes the attested
  products from the queue run's artifacts by run id, and checks their
  attestation against that run.
- Waits on: nothing. It is independent of 1.1 and could land first.
- Shows: a main push whose SHA passed the queue finishes in under 3 min
  wall, and its prerelease names the queue run as its source. A push
  to main without a queue run (a manual push, a queue bypass) still
  runs the full scope.

### 1.3 The checked suite in its own job, if 1.1 leaves it long

After 1.1, the suite stands on every commit that moves neither the core
nor the runner. What remains is the commits that do, which are about
half of them now and fewer after stage 2.

- Decision point, after 1.1 lands: on the last 20 gating runs, count
  how often linux-x86_64 exceeds the next-slowest leg by more than 2
  min. Split the job only if it is more than a quarter of them.
- Change, if split: a `checked-linux-x86_64` job runs a new `platform
  checked-suite` phase: a boot without the local suite, `bin/zig build
  sanitized`, and the suite. It restores the leg's zig and compiles
  caches without saving them, keeps `checked.db` under its own cache
  prefix, and uploads diagnostics on failure. Set
  `COSMIC_CI_CHECKED_SUITE=skip` on every leg, since assemble still
  verifies the core. The `ci` job needs `[platform, checked]`. The new
  job is not a matrix entry, since `job-total` feeds attestation.
- Shows: linux-x86_64 is no longer the slowest leg on a cold commit.

### Milestone M1

- A gating run on a commit that moves neither the core nor the runner
  takes under 9 min wall. On such a commit the checked suite stands on
  at least 90% of its tests.
- A main push after a green queue run takes under 3 min.
- Runner-minutes per landed change are about half of today's.

## Stage 2: an edit reruns what it implicates (one to two weeks)

This stage is local speed, and CI's on the commits stage 1 left cold.
The order follows what each item unblocks.

### 2.1 Narrow the closure every key holds (new)

Every sandboxed key holds the harness, which includes the code that
computes the key and looks up verdicts. That code is `build.test`,
`build.declared_key` and `build.shared_verdicts`, each by its import
closure. `build.test`'s closure is most of the build and much of the
standard library: `build.work`, `build.importer`, `build.compiler`,
`build.teal`, `cosmic.fs`, `cosmic.hash` (and through it
`cosmic.codec`), `cosmic.sqlite`, `cosmic.child` and more. So a comment
in any of those reruns every test, and 27 of the last 50 commits did.

- Change: the code that decides a verdict becomes a small module with
  its own narrow closure (a `build.verdict_core`, say). It holds the key
  computation, the lookup and the worker's protocol, and is the only
  part of the runner the harness digest holds. Scheduling, reporting,
  coverage and the census stay in `build.test`, out of every key. A
  test in the manner of `build/compiler_readers_test.tl` pins the core's
  closure, so a new require into it is a deliberate edit.
- This takes in two items that were separate before. One is the
  cache-locating variables moving into `build.cache_names`
  (`build/test_inputs.tl`'s `TODO:`), which ends the rerun on an edit
  to `build/zig.tl`. The other is the sandbox plan keyed by what it is
  rather than by `build/test_sandbox.tl`'s source (`build/test.tl`'s
  `TODO:`).
- Shows: a comment in `cosmic/codec.tl`, `build/work.tl` or
  `build/test.tl`'s reporting code reruns only the tests that import
  it, which is under a quarter of the suite, not all of it.

### 2.2 Observation removal, PR 1 (#2285)

The sandbox and process helpers leave the observation log's module:

- `build.confine` takes the spawn stand-in as `enter`, plus
  `confine`/`must_confine`, `forbid_running`, `worker_unveil`,
  `itself`, `held_to_sandbox` and a Teal `resolution`.
- `build.this_program` takes `program` and `environment`.
- `key_part` and `tree_name` move into `build.declared_key`.

Behavior is identical. The harness digest moves once, so land it in the
same week as 2.1's first PR and pay the cold run once.

### 2.3 Tool and store floor, batch 2

Of the tests keyed by the whole program (`tool`) or the whole projection
(`store`), batch 1 (#2283) took 245 off. Batch 2 takes the modules with
3 or more tests to move: core/syscalls_test (65 of 80),
build/filesystem_observations_test (30 of 44), cosmic/child_test, the
sandbox tests, and about 15 smaller ones. Each is split as
`<module>_tool_test.tl` or `<module>_store_test.tl`. This takes the
floor from about 542 tests to about 355.

- Shows: a comment in `cosmic/shape.tl` reruns under 300 tests (582
  today).

### 2.4 Stand-in built once per run

`build/stand_in.tl` builds a whole tree with `embed.tree` in a child
for every test that needs one. That is about 1 s on the release core
and 3 s on the checked core, for about 40 tests: 31 s of release test
time and 100 s checked. Workers are one process per test, so no
in-process memo helps.

- Change: `stand_in.build` compiles only `cmd/probe/main.tl` against
  the carried modules (the `TODO:` there; it waits on `build.embed`
  taking a prebuilt store). That also frees 62 tests from `tool`.
  Failing that, the runner builds the stand-in once under `o/`, and
  tests declare it as `tool` tests declare the program.
- Shows: the checked suite, cold, is about 100 s shorter.

### 2.5 Key precision, smaller

- The writer identity is over-wide (`build/work.tl`'s `TODO:`). Make
  roots for what a projection depends on, plus a guard like the
  compiler's.
- Name the analyzer by what a parse runs, not the whole compiler
  identity (`build/importer.tl`'s `TODO:`). This moves every parse key
  once.
- The settle when one commit moves both the fingerprint's definition
  and the compiler identity's (`build/reboot.tl`'s `TODO:`).

### Milestone M2

These are measured with the recipe in "Measuring", below.

- A comment in `cosmic/codec.tl` reruns under a quarter of the suite
  (all of it today).
- A comment in `cosmic/shape.tl` reruns under 300 tests (582 today).
- The tool/store floor is at most 355.
- Over the ten merges after M2, the gating run's checked suite stands
  on at least 70% of its tests.

## Stage 3: soundness, before the cache is trusted more (one to two weeks)

Stage 4 turns declared keys on for every unsandboxed run and deletes
the observed path. Each of these holes lets a verdict stand that a
rerun would fail, so they close before that stage.

### 3.1 Refuse the retained artifact descriptor

A portable start keeps a descriptor on the artifact
(`COSMIC_PORTABLE_ARTIFACT_FD`). A test can read every carried module
through it, past the worker's hold on the store and past every key
(the `TODO:` in `core/syscalls_fs.c`).

- Change: every binding that takes a descriptor refuses that one from
  Lua. That covers `read`, `pread`, `lseek`, `fstat`, `dup`, `dup2`,
  `fd_flags`, and `spawn`'s descriptor map and standard streams, plus
  an open of `/proc/self/fd/<it>` or `/dev/fd/<it>`. It uses
  `cosmic_store_artifact`.
- Shows: a test that tries each one is refused, on the checked core as
  well.

### 3.2 Hold `Store.meta`

A worker's `Store.meta` reads are not held (`build/test_worker.tl`'s
`TODO:`). Outside the `compiler_readers` allowlist, a meta key read by
a module is neither refused nor keyed.

- Change: `hold_store` holds `Store.meta` to the keys a test's closure
  may read, and the key holds each meta row it allows.
- Shows: a test module that reads an unlisted meta key fails, and names
  the declaration that would allow it.

### 3.3 Platform-only code on macOS (new)

The rule lets macOS key its runs without enforcing them "because the
Linux legs hold the same tests sandboxed". That is not true of a darwin
branch: a read only macOS takes is enforced nowhere.

- Decision, one of these:
  - (a) The macOS leg's gating run stands on nothing for a test module
    whose closure includes a module that branches on the platform
    (`Sys.platform`, `os == "darwin"`, found by the build's catalog).
  - (b) The macOS leg's scheduled run is `--all`, and the report in 0.1
    is the backstop.
- (b) is what exists today and needs nothing. (a) is sounder, at the
  cost of a slower macOS leg on some commits. Choose once 1.3 says
  whether macOS is the long pole.

### 3.4 Smaller gaps from the #2271 review

Each has a `TODO:` unless noted:

- `cosmic.removed` and a module's file are not in the local compile key
  (`build/work.tl`, `build/importer.tl`).
- `eval/` and `test/portable` are carried but are not tool trees
  (#2258).
- IPv6 in a new network namespace is unkeyed (`build/declared_key.tl`).
- A file under `/usr` changed outside a package goes uncaught by
  `system_identity`.
- `/proc/self/mountinfo` names each bind's host source
  (`build/test_sandbox.tl`).

The raw tables reached through `cosmic.sqlite`'s searcher, and a store
connection through a borrowed handle, close with 4.2's PR 5.

### Milestone M3

- 3.1 and 3.2 have landed, and each has a test that tries the hole.
- 3.3 is decided and written in ci.yml's comment on the macOS leg.
- No soundness `TODO:` from the #2271 review is left without an owner
  item here.

## Stage 4: fewer paths, less code (two to three weeks)

Once stage 3 has closed its holes, this stage deletes the parallel
machinery.

### 4.1 Fixtures sandboxed, sharing verdicts (branch `fixtures-sandboxed`)

Each fixture declares what it reads with `Test.needs`, host paths by
the variable that names them (`$COSMIC_FIXTURE_PRODUCT`, #2279).

- The runtime directory gets copies of `tool.tl`'s closure and the
  focused-embed build, with cores made executable at setup.
- The driver unpacks `work/portable-source.tar` as
  `COSMIC_FIXTURE_SOURCE`. The checkout's `.git` changes every run, so
  no fixture declares the root.
- Inner `cosmic test` runs get `COSMIC_TEST_SANDBOX=0` explicitly.
- `format` stays an unsandboxed setup step.
- The launcher's noexec case moves to an unsandboxed module of its own,
  with a `TODO:`.
- `Orchestration.fixture` drops the sandbox-off and no-shared settings,
  keeps `COSMIC_BUILD_CACHE=0`, and writes `fixtures.db` beside
  `verdicts.db`.
- The same PR moves `ci/cosmic-driver.pin` to a prerelease carrying
  #2279, and takes up the `TODO:`s that unblocks.

The design note behind this item goes into the PR's description, not
session scratch.

- Shows: runtime, launcher, identity and product stand on a commit that
  moves neither the product nor the fixtures (25 to 40 s a leg). They
  ran about 2 min a leg before. Self-rebuild, fixed-point and
  self-driven key on the whole source, and keep running on most
  commits.

### 4.2 Observation removal, PRs 2 to 5

- PR 2: `--audit` from the sandbox's refusals. A sandboxed failure's
  message names the path the sandbox refused. The runner suggests the
  declaration from it, with an optional widened rerun.
- PR 3: declared keys become the default for every unsandboxed run,
  retiring `COSMIC_TEST_KEY`. Such a run shares only when
  `COSMIC_VERDICT_CACHE` names a file, which CI's macOS leg does, and
  never through the home cache. Waits on PR 2, 4.1 and stage 3.
- PR 4: delete the observed key path (`standing`, `assumable`,
  `test.verdict_key`, `identity_of`, the assumed path), the `reads`
  column of `runs`, `Test.needs.processes`, and the worker's logging.
  That is about 2,500 lines of Teal.
- PR 5: delete `core/observed.c` and its 29 syscall hooks, the observed
  SQLite VFS, and `core/store.c`'s observe knobs. That is about 1,900
  lines of C and 65 C functions.
- Measure before PR 4 and after PR 5, with the recipe in "Measuring":
  - a full run's ran, stood and elapsed
  - the checked suite's time
  - the core's size
  - the C function count
  - the size of `o/build.db`

### 4.3 One cache verb in CI (new)

ci.yml has three copies of "look up the newest entry, check whether a
descendant saved it, save", one each for verdicts, compiles and the
driver-check marker. Each is two or three steps and long `if:`
expressions. The SQLite open/WAL/corruption/set-aside code has three
copies too: `build/shared_compiles.tl`, `build/shared_verdicts.tl` and
`ci/cosmic_ci/cache_trim.tl`.

- Change: a local composite action, `.github/actions/cache-newest`,
  takes a path, a key prefix and whether to check ancestry. The
  decision moves into a driver verb, tested in `orchestration_test.tl`,
  with `save-unless-descendant.sh` folded into it. One module takes the
  shared SQLite plumbing, and the eviction policies stay per cache.
  `cache_trim.tl` calls the tools' own trim verb, as its `TODO:` asks.
- Shows: fewer steps per Linux leg (47 today, at least 10 fewer), and
  ci.yml's cache logic is covered by a driver test.

### 4.4 macOS follow-ups

- The unenforced worker sees the checkout's real path, and no key holds
  it (`build/test.tl`'s `launch`, `TODO:`). Give it the tree at a fixed
  path, or key the path.
- The unenforced worker gets the whole projection, not its closure
  store (`TODO:` in `launch`). This waits on `cosmic test --worker`
  taking `--store`.
- Still unkeyed or unread:
  - Groups on macOS (waits on `cosmic.sys` carrying getgroups).
  - A developer's Mac beyond the sealed volume, without
    `COSMIC_SYSTEM_ID`.
  - The OS cryptex's `SystemVersion.plist`, which is not read.

### Milestone M4

- `COSMIC_TEST_KEY`, the observed path and `core/observed.c` are gone,
  with their line counts in the PR descriptions.
- Fixtures stand on most commits.
- ci.yml's cache handling is one action and one driver verb.

## Dropped or deferred

- Portable suite narrowed to the tests that depend on the artifact:
  dropped. It already stands (17 s a leg on a commit that leaves its key
  alone), so narrowing would save little and add a selection rule to
  trust.
- Fixtures run concurrently in one leg: deferred until after 4.1. Once
  most of them stand, what is left is self-rebuild, fixed-point and
  self-driven. Those contend for 4 cores, and fixed-point already runs
  on one leg (#2281). Measure after M4.
- Local eviction of the zig caches (`zig-project`, `zig-global`; about
  720 MB after one boot): goes to roadmap.md. It is disk, not
  correctness, and AGENTS.md already says to delete them.
- The driver check's marker keyed by event, and the self-driven and
  checked tool-entry bounds far above their times: folded into 1.2 and
  4.3, where those steps change anyway.

## Measuring

Each milestone repeats these measurements, and its PR description
records them:

- CI: wall time of the last 10 gating runs and main pushes (the
  `list_workflow_runs` durations), each leg's step times, and each
  suite's `ran`/`stood` line from the logs.
- Local: on a 4-core Linux host, sandboxed, from a checkout at the
  milestone's commit, with the verdict rows deleted from `o/build.db`
  and `COSMIC_VERDICT_CACHE=0` for the cold run. Then the comment
  probes, one at a time and reverted between them: a line appended to
  `cosmic/codec.tl`, `cosmic/shape.tl`, `build/work.tl` and one test
  file. Record ran, stood and elapsed for each.

## Landed (this effort)

- Shared compiles and parses across checkouts (#2259, #2268). CI
  restores and saves them per leg (#2261). A fresh boot went from 31 s
  of CPU to 7 s.
- The harness keyed by what a worker loads (#2262, #2266), plain
  bytecode for the key's own code (#2265), and closure stores salted by
  the writer's closure (#2271, #2273).
- Compiler identity by what shapes a compile (#2278): an edit to
  `build/zig.tl` moves 37 of 292 module keys, not all, and needs no
  settle.
- The `system` declaration and five batches taking tests off the
  host's package identity, with a stand-in program replacing shell
  scripts in tests (#2257, #2260, #2263, #2264, #2269, #2274).
- Verdict caches saved unless a descendant's save is newest (#2275),
  trimmed to a leg's run (#2270), and bounded (#2272's follow-ups).
- `COSMIC_SANDBOX=must` on every Linux leg (#2276).
- `Test.needs` host paths named by a variable (#2279), and the driver
  pin moved (#2277).
- Declared keys without a sandbox, and the macOS host identity (#2280).
  The macOS leg stands on them with its own verdict cache (#2282).
- The fixed-point regression on one gating leg (#2281).
- Tool and store floor, batch 1: 245 tests off, so a comment edit to
  `build/dispatch.tl` reruns 546 tests, not 1984 (#2283). `SHLVL` is
  out of the environment key.
- The checked suite bound at twice its measured time, with its per-test
  times in the failure diagnostics (#2272).
