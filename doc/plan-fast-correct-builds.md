# plan: fast, correct builds and tests

Working plan for building and testing only what a change implicates,
with the cache relied on and the sandbox enforcing it, locally and in CI.
Each item names what it changes, what it waits on, and what shows it
worked. Landed work is listed at the end for the record and leaves this
file once the plan closes; [roadmap.md](roadmap.md) holds work with no
plan yet.

The rule every item serves: a test's verdict is keyed by the digest of
its declared inputs (`Test.needs`, its import closure, the core, the
host), and the sandbox holds the worker to those inputs. Nothing keys by
what a process was seen to read; the macOS leg, which has no sandbox,
keys the same way unenforced, because the Linux legs hold the same tests
sandboxed.

## 1. In flight

### 1.1 Checked core byte-stable (branch `checked-core-stable`)

The checked suite (the whole suite on the sanitized core) stood on no
verdict in any CI run: the core keeps debug info, and two things in it
name the run. Each object's `DW_AT_comp_dir` is the tree root of
whichever build first compiled it (zig's object cache keeps old paths),
and the generated `coverage_map.c` is named by its zig-cache output
directory, new on every relink. The stripped release cores have neither.

- `build.zig`: `-fdebug-compilation-dir=.` on every C flag set (own C,
  the coverage map, every vendored library), `-g0` on the generated map.
- `ci/cosmic_ci/orchestration.tl`: assert the checked core's bytes name
  no `DW_AT_comp_dir` but `.` and no cache `coverage_map.c` path; the
  checked suite writes `checked.db` beside the leg's `verdicts.db`, and
  runs with `cosmic test --census`, which prints the key-part line even
  where the local suite ran first, launcher and program parts included.
- Open from review: musl is built in zig's global cache without these
  flags and keeps the comp_dir of whichever checkout first built it, so
  the digest is stable only while that cache lives; the assertion must
  search the bare root path; under `ci/run-local` the project cache sits
  in the tree and vendor `__assert_fail` strings name it, so the
  assertion must exclude the cache prefix. A `TODO:` records what musl
  waits on.
- Shows: `checked suite: ... stood` on the second main run after a
  commit that moves neither the core nor the runner; 224-313 s down to
  under 40 s on linux-x86_64.

### 1.2 Fixtures sandboxed, sharing verdicts (branch `fixtures-sandboxed`)

Design: `design-fixtures-sandboxed.md` (session scratch). Each fixture
declares what it reads with `Test.needs`, host paths by the variable
that names them (`$COSMIC_FIXTURE_PRODUCT`, landed in #2279): the
runtime directory gets copies of `tool.tl`'s closure and the
focused-embed build, cores made executable at setup; the driver unpacks
`work/portable-source.tar` as `COSMIC_FIXTURE_SOURCE` (the checkout's
`.git` changes every run, so no fixture declares the root); inner
`cosmic test` runs get `COSMIC_TEST_SANDBOX=0` explicitly; `format`
stays an unsandboxed setup step; launcher's noexec case moves to an
unsandboxed module of its own with a `TODO:`; `Orchestration.fixture`
drops the sandbox-off and no-shared settings, keeps
`COSMIC_BUILD_CACHE=0`, writes `fixtures.db` beside `verdicts.db`, and
no longer clears `COSMIC_TEST_KEY` (macOS fixtures key by declaration
too). The same PR moves `ci/cosmic-driver.pin` to a prerelease carrying
#2279, since the pinned driver runs the fixtures, and takes up the TODOs
the pin unblocks.

- Waits on: nothing; the prerelease of #2279's merge exists.
- Shows: runtime, launcher, identity and product stand on a commit that
  moves neither the product nor the fixtures (25-40 s a leg); enforcement
  of every fixture's reads. Self-rebuild, fixed-point and self-driven key
  on the whole source and keep running on most commits; fixed-point
  already runs on one gating leg (#2281).

### 1.3 Observation removal, PR 1 (branch `observation-move-helpers`)

Plan: `plan-remove-observation.md` (session scratch). The sandbox and
process helpers leave the observation log's module: `build.confine`
(the spawn stand-in as `enter`, `confine`/`must_confine`,
`forbid_running`, `worker_unveil`, `itself`, `held_to_sandbox`, a Teal
`resolution`), `build.this_program` (`program`, `environment`),
`key_part`/`tree_name` into `build.declared_key`. Behavior identical;
the harness digest moves once because every worker now loads five more
modules (a `TODO:` drops `build.artifact` and `build.launcher` from
`worker.loads` once steps 4 and 5 remove their worker-side users).

## 2. Next, in order

### 2.1 Checked suite in its own job

After 1.1. A `checked-linux-x86_64` job runs a new `platform
checked-suite` phase: boot without the local suite, `bin/zig build
sanitized`, the suite; it restores the leg's zig and compiles caches
without saving them, keeps `checked.db` under its own cache prefix,
uploads diagnostics on failure. `COSMIC_CI_CHECKED_SUITE=skip` on every
leg (assemble still verifies the core). The `ci` job needs `[platform,
checked]`; not a matrix entry, since `job-total` feeds attestation.
Shows: linux-x86_64 from about 783 s to about 510 s; macOS becomes the
slowest leg.

### 2.2 Tool and store floor, batch 2

After 1.3. Census: `census-tool-store.md` (session scratch): of 787
tests keyed by the whole program (`tool`) or projection (`store`), 455
pass without the declaration sandboxed and audit-clean. Batch 1 (#2283)
took 245 off. Batch 2: the remaining modules with 3 or more tests to
move (core/syscalls_test 65 of 80, build/filesystem_observations_test 30
of 44, cosmic/child_test, the sandbox tests, and about 15 smaller), each
split as `<module>_tool_test.tl`/`_store_test.tl`. Floor from about 542
to about 355. Two further levers: the stand-in built without the program
(62 tests, item 2.5) and `-e` children held to their worker's closure
store (many of the 167 that start the program).

### 2.3 Observation removal, PRs 2 to 5

- PR 2: `--audit` from the sandbox's refusals. A sandboxed failure's
  message names the path the sandbox refused; the runner suggests the
  declaration from it, with an optional widened rerun. No C log of
  refusals (it would need the same per-binding hooks). Loses: reads that
  tolerate absence go unnamed, one refusal per failure rather than every
  read; on Linux the verdict stays sound since the sandbox enforces.
- PR 3: declared keys the default for every unsandboxed run, retiring
  `COSMIC_TEST_KEY`; such a run shares only when `COSMIC_VERDICT_CACHE`
  names a file (CI's macOS leg does), never through the home cache. The
  identity fixture's "relocated project reruns" check flips. Waits on PR
  2, #2282 (landed) and 1.2.
- PR 4: delete the observed key path (`standing`, `assumable`,
  `test.verdict_key`, `identity_of`, the assumed path), the `reads`
  column of `runs`, `Test.needs.processes`, and the worker's logging,
  which every sandboxed worker still turns on only to fill that column.
  About 2,500 lines of Teal.
- PR 5: delete `core/observed.c` and its 29 syscall hooks, the observed
  SQLite VFS and `core/store.c`'s observe knobs (gaps 3 and 4 of the
  #2271 review). About 1,900 lines of C, 65 C functions.
- Measure before PR 4 and after PR 5: a full run with verdicts deleted
  and `COSMIC_VERDICT_CACHE=0` (ran, stood, elapsed), the checked suite's
  time, core size, the C function count, `o/build.db` size.

### 2.4 macOS follow-ups

- The unenforced worker sees the checkout's real path and no key holds
  it (`build/test.tl`, `launch`'s keyed branch, `TODO:`): give it the
  tree at a fixed path, or key the path. Until then only the scheduled
  run catches a path-dependent test on macOS.
- The unenforced worker gets the whole projection rather than its
  closure store (`TODO:` in `launch`; waits on `cosmic test --worker`
  taking `--store`).
- Groups unkeyed on macOS (waits on `cosmic.sys` carrying getgroups); a
  developer's Mac beyond the sealed volume unkeyed without
  `COSMIC_SYSTEM_ID`; the OS cryptex's `SystemVersion.plist` not read.
- Evidence to collect: the macOS leg's first standing main run (main
  saved its first macOS verdicts after #2282).

### 2.5 Stand-in built once per run

`build/stand_in.tl` builds a whole tree with `embed.tree` in a child for
every test that needs it: about 1 s on the release core, 3 s checked,
about 40 tests since #2269 (31 s of release test time, 100 s checked).
Workers are one process per test, so no in-process memo helps. Either
the runner builds it once under `o/` and tests declare it (keyed by the
program's identity as `tool` tests are), or `stand_in.build` compiles
only `cmd/probe/main.tl` against the carried modules (the `TODO:` in
`stand_in.build`; waits on `build.embed` taking a prebuilt store). Also
frees 62 tests from `tool`.

### 2.6 CI shape, from the timeline

From `ci-timeline.md` (session scratch), six main runs:

- Main re-runs the SHA the merge queue already passed: about 10 min and
  50 runner-minutes a push. A lighter main job that saves the caches and
  lets `prerelease.yml` take its products from the merge-queue run.
- The portable suite (107 s a leg) narrowed to tests that depend on the
  artifact.
- Fixtures run one after another and each compiles its 33-module project
  from scratch (2.2 s each): run them together, build the project once
  (40-80 s a leg, CPU contention risk on 4 cores).
- Hygiene: the self-driven and checked tool-entry bounds are far above
  their actual times (their TODOs); the driver-check marker key includes
  the event name, so a `ci/**` change costs both the merge-queue and main
  runs 22-34 s.

### 2.7 Key precision, smaller

- `build/test_inputs.tl` (`TODO:`): the cache-locating variables move
  into `build.cache_names`, so an edit to `build/zig.tl` stops rerunning
  every sandboxed test (it still does, through `build.caches`' lazy
  require of `build.zig` in the key-computing code).
- The writer identity is over-wide (`build/work.tl`, `TODO:`): roots for
  what a projection depends on, plus a guard like the compiler's.
- The analyzer named by what a parse runs, not the whole compiler
  identity (`build/importer.tl`, `TODO:`; moves every parse key once).
- The sandbox plan keyed by what it is, not by `build/test_sandbox.tl`'s
  source (`build/test.tl`, `TODO:`).
- The settle when one commit moves both the fingerprint's definition and
  the compiler identity's (`build/reboot.tl`, `TODO:`).
- Verdicts shared across runners of a leg once `system_identity` names
  what a package database does not (`ci/cosmic_ci/orchestration.tl`,
  `TODO:`).

### 2.8 Soundness gaps left open (from the #2271 review)

Each has a `TODO:` unless noted: `Store.meta` unheld for a test without
`store` or `tool` (`build/test_worker.tl`); raw tables reached through
`cosmic.sqlite`'s searcher carry `observe`/`observed`/`exclude_held`
(closed by 2.3 PR 5); a store connection through a borrowed handle
excluded from capture (same); `cosmic.removed` and a module's file not
in the local compile key (`build/work.tl`, `build/importer.tl`);
`eval/` and `test/portable` carried but not tool trees (#2258); IPv6 in
a new network namespace unkeyed (`build/declared_key.tl`); a file under
`/usr` changed outside a package uncaught by `system_identity`; the
retained artifact descriptor readable from Lua (`core/syscalls_fs.c`);
`/proc/self/mountinfo` names each bind's host source (`build/
test_sandbox.tl`); nothing reports a red main or nightly run (no TODO).

## 3. Landed (this effort)

- Shared compiles and parses across checkouts (#2259, #2268); CI
  restores and saves them per leg (#2261); fresh boot 31 s CPU to 7 s.
- Harness key by what a worker loads (#2262, #2266), plain bytecode for
  the key's own code (#2265), closure stores salted by the writer's
  closure (#2271, #2273).
- Compiler identity by what shapes a compile (#2278): an edit to
  `build/zig.tl` moves 37 of 292 module keys, not all, and no settle.
- The `system` declaration and five batches taking tests off the host's
  package identity, with a stand-in program replacing shell scripts in
  tests (#2257, #2260, #2263, #2264, #2269, #2274).
- Verdict caches saved unless a descendant's save is newest (#2275),
  trimmed to a leg's run (#2270), bounded (#2272's follow-ups).
- `COSMIC_SANDBOX=must` on every Linux leg (#2276).
- `Test.needs` host paths named by a variable (#2279); the driver pin
  moved (#2277).
- Declared keys without a sandbox and the macOS host identity (#2280);
  the macOS leg standing on them with its own verdict cache (#2282).
- Fixed-point regression on one gating leg (#2281).
- Tool and store floor batch 1: 245 tests off; a comment edit to
  `build/dispatch.tl` reruns 546 tests, not 1984 (#2283); `SHLVL` out of
  the environment key.
- Checked suite bound at twice its measured time, with its per-test
  times in the failure diagnostics (#2272).
