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
waits for the soundness fixes that make that step safe.

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
  step yet (0.3 records one).
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

## Stages 0 and 1: done (2026-09-28)

Every item merged; see "Landed" for the PRs.

- 0.1 key guards (#2287)
- 0.2 one rebuild at a time (#2288)
- 0.3 suite rows and `report` (#2289)
- 0.4 the artifact descriptor refused (#2290)
- 1.1 checked suite stands (#2286, #2292)
- 1.2 `Store.meta` held (#2293)
- 1.3 plain caches (#2291)

What the runs since show:

- On a commit that moves neither the core nor the harness, the
  checked suite stood on 1,975 of 1,994 tests. `assemble` fell from
  5.5 min to 60 s, and linux-x86_64 from 13.5 min to 5.5.
- #2291's merge-queue run took 6.3 min and its main push 6.5, against
  11 to 16 min before.
- A commit that moves the core or the harness still reruns every test
  once: 15 to 16 min in the queue.

### Milestone M1 (to measure)

M1 is decided with `driver.tl report` over ten qualifying gating
runs, which this container cannot run (no `gh`). Its targets:

- the median gating run under 9 min;
- the checked suite standing on at least 90%;
- a main push that moves neither the core nor the harness under 6 min;
- runner-minutes per landed change under 45.

## Stage 2: an edit reruns what it implicates (two weeks)

2.1, #2285, has landed.

### 2.2 Key tests by a harness epoch

Every sandboxed key holds three things beyond the test's own inputs:

- the harness digest: what a worker loads, plus `harness_own`;
- `build.test` by its source;
- the 38-module closure of the key's own code (`key_code`).

27 of 50 commits moved one of these, and each reran every test in every
checkout and leg. The epoch replaces all three with a number that moves
only when someone decides a change to the harness can change a verdict.

- Change, the key:
  - A test's key holds its import closure, its declarations, the core,
    the host, and a new `timeout` part (closing `build/test.tl`'s
    `TODO:` on the unkeyed timeout).
  - It also holds `epoch` from `build/harness_epoch.tl`.
  - The harness digest, `build.test`'s source and `key_code` leave it.
  - A module the worker loads that the test's own closure also
    requires stays keyed through that closure, as today.
- Change, the guard: `build/harness_epoch.tl` also holds an
  acknowledged digest of the harness files: `worker.loads`,
  `harness_own`, `build.test`, and `key_code`'s closure.
  `build/harness_epoch_test.tl` fails when that digest moves. Its
  message names the choice:
  - bump `epoch` if the change can alter a pass or a fail (what a
    worker is given, how it is judged, how a key is computed);
  - otherwise update the digest.

  The choice is then one reviewable line in the diff.
- Change, the backstop: a merge-queue run whose change moves
  `build/harness_epoch.tl` runs every suite with `--all`, so a harness
  change is gated on a full run of every test before it lands. The base
  comes from `github.event.merge_group.base_sha`, and orchestration.tl's
  `stands` takes it. Branch pushes and local runs do not pay this.
- Kept:
  - The harness's own tests import `build.test` and rerun on every edit
    to it, as today.
  - 0.1's field and preimage guards still hold `build.declared_key`.
  - The nightly `--all` run.
- Accepted:
  - A harness change recorded as "keep" that does alter a verdict
    stands until the merge queue's `--all` (before landing) or the
    nightly run catches it.
  - The tree's module names, which a worker's hold refuses, are not
    keyed: a new module can only change a test that requires it, and
    then its closure moves.
- Waits on: nothing.
- Shows:
  - a comment in `build/test.tl`, `build/zig.tl` or `cosmic/http.tl`
    reruns only the tests that import it, plus the `harness_epoch` test;
  - a merge-queue run of such a change runs `--all`.

### 2.3 Stand-in built once per run

`build/stand_in.tl` builds a whole tree with `embed.tree`, in a child,
for every test that needs one. That costs about 1 s on the release
core and 3 s on the checked core, for about 40 tests: 31 s of release
test time and 100 s of checked. It is also most of why
`build/test_isolation_test.tl`'s hung-test case takes about 6 of its
10 s, and timed out once under load (#2293).

- Change, first PR: `build.embed` takes a prebuilt store (the `TODO:`
  in `stand_in.build`).
- Change, second PR: `stand_in.build` compiles only `cmd/probe/main.tl`
  against the carried modules. This frees 62 tests from `tool`.
- Failing that, the runner builds the stand-in once under `o/`, and
  tests declare it as `tool` tests declare the program.
- Shows:
  - the checked suite, cold, runs about 100 s shorter;
  - the isolation test takes under 4 s alone.

### 2.4 Tool and store floor, batch 2

Batch 1 (#2283) took 245 tests off `tool`/`store`. Batch 2 takes the
modules with 3 or more tests to move, each split into
`<module>_tool_test.tl` or `<module>_store_test.tl`:

- `core/syscalls_test` (65 of 80)
- `build/filesystem_observations_test` (30 of 44)
- `cosmic/child_test`
- the sandbox tests
- about 15 smaller modules

Its prerequisites, 0.4 and 1.2, have landed.

- Shows: the floor, counted by a named `o/bin/cosmic sql` query over
  the catalog's `tool` and `store` declarations, is about 355 (about
  542 before). 2.3's 62 freed tests lower it further.

### 2.5 Key precision, smaller

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
- A comment in `cosmic/shape.tl` reruns at most 400 tests (582 before).
- A comment in `build/zig.tl`, `cosmic/http.tl` or `build/test.tl`
  reruns at most 400. Each reran every test before.
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

- Decision: the macOS leg's scheduled run stays `--all`, and is the
  backstop.
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

- Waits on: stage 3, and a prerelease carrying #2279.
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

### 4.3 One SQLite module for the shared caches

The SQLite code for opening a cache (WAL, busy timeout, corruption
detection, setting a corrupt file aside) has three copies:
`build/shared_compiles.tl`, `build/shared_verdicts.tl` and
`ci/cosmic_ci/cache_trim.tl`. The last one also reaches into the
tools' tables directly.

- Change: one module holds the shared code. Each cache keeps its own
  row shape and eviction policy.
- Change: `cache_trim.tl` calls the tools' own trim verb, as its
  `TODO:` asks, and prints the content digest 1.3's save key uses.
- Waits on: 1.3. This item is maintainability, not speed.
- Shows: the three copies are one, and `cache_trim.tl` reads no
  table of the tools' directly.

### Milestone M4

- `COSMIC_TEST_KEY`, the observed path and `core/observed.c` are gone,
  with their line counts in the PR descriptions.
- The fixtures' rows show them standing on the median gating run.
- The shared caches open through one module.

## Milestones

Each milestone is decided from 0.3's `report`, as follows.

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

- **The checked suite in its own job** (was 2.3): dropped. With the
  checked suite standing, linux-x86_64 is no longer the long pole
  (about 5.5 min).
- **Narrowing the key code's closure** (was 2.2 (a) to (d)):
  superseded by the harness epoch (2.2).
- **Report a red scheduled run, and pull its verdict:** dropped. The
  `TODO:` on ci.yml's `schedule` stays.
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

- **Stages 0 and 1** (2026-09-28):
  - 0.1 key guards (#2287)
  - 0.2 one rebuild at a time (#2288)
  - 0.3 suite rows and `report` (#2289)
  - 0.4 the artifact descriptor refused (#2290)
  - 1.1 checked core keyed stably (#2286, #2292)
  - 1.2 `Store.meta` held (#2293)
  - 1.3 plain caches (#2291)
  - #2293 also fixed a sandbox mount race on the cores directory's
    stamp.
- **Observation removal, PR 1** (#2285).
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
