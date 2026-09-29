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

Before an item gets a target, a census of the code sets it: stage 2's
estimates were off whenever they came from reading alone (the
isolation test's time, the floor, the count of `store` modules).

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

**Second measurement (2026-09-29, 13 gating runs after #2320,
#2326 to #2334).** 7 qualify (core and harness unmoved); 10 are
needed, so M1 is not yet decided. Over the 7:

- Median gating run 10.8 min: missed (target under 9).
- Checked suite stands on a median 55.7%, best 74.6%: missed (90).
- Main push median 56 s, at most 90 s: met (under 6 min).
- 35.9 runner-minutes per landed change: met (under 45).

Why runs don't stand, from the runs and a local reproduction:

1. Six of 13 went `--all`: their PR changed a module
   `build/harness_epoch.tl` acknowledges. Its 44 modules include
   `cosmic.time`, `codec`, `hash`, `stream`, `fs`, `string`, `sqlite`,
   `store` and `build.analyzer`, which ordinary PRs edit.
2. An edit to any `*.d.tl` moves every test's key: every closure store
   carries every declaration whole (`build/closure_store.tl`), and a
   test's key holds its store's address. #2327 renamed two parameters
   in `cosmic/internal/store.d.tl`, and 2216 of 2216 ran.
3. Queue runs stack: each restores main's newest seed, 0 to 2 commits
   behind, and inherits what the runs ahead of it changed.
4. About 540 `tool`/`store` tests rerun on any code edit, so a code
   change stands on at most about 75%; they are also the slow tests,
   so standing barely shortens the checked suite. 90% of about 2400
   means at most 240 run, under 2.4's floor.

The gate itself is linux-x86_64 in 9 of 13 runs: its checked suite
takes 178 to 345 s and its fixtures 95 to 163 s; macOS's fixtures take
170 to 266 s. 4.5's item 3 and the fixture items move it; more tests
standing does not.

Decided (2026-09-29):

- Shrink what every worker loads, so the harness set holds only the
  code that judges a test and makes its key, not the standard library
  (2.7). The queue's `--all` on any change to `build/harness_epoch.tl`
  stays.
- A closure store carries only the declarations its closure needs
  (2.8).
- M1's 90% stays; the way there is fewer `tool` and `store` tests
  (2.4's work continued, and 3.0b), not a softer target.
- The gate's time comes next in 4.5: the checked suite in its own job,
  then the fixtures (items 3 to 5), ahead of merge-base restores.

(The first measurement follows.)

A first measurement (2026-09-28): only 1 of 5 gating runs after #2291
qualified. It stood on 96.6% of the checked suite, gated in 6.0 min, and
took 43.8 runner-minutes. The other three landed changes moved the core
or the harness and reran everything: 14.4 min median gating, 81
runner-minutes per change, no better than before. Stages 0 and 1
themselves rewrote what every key holds. 2.2 has landed, so M1 is
measured again over the next ten ordinary commits; stage 2's own PRs
moved the harness and do not qualify.

Before that measurement, `ci/cosmic_ci/report.tl:257` (small): have
`cosmic test --census` name the key parts of the rows it restored, so
`report` qualifies a run by the restored cache's parts, not the
previous run's.

M1 is decided with `driver.tl report` over ten qualifying gating
runs, which this container cannot run (no `gh`). Its targets:

- the median gating run under 9 min;
- the checked suite standing on at least 90%;
- a main push that moves neither the core nor the harness under 6 min;
- runner-minutes per landed change under 45.

## Stage 2: an edit reruns what it implicates (two weeks)

2.1 (#2285), 2.2 (#2295), 2.3 (#2296) and 2.5 (#2294) have
landed, and 2.4 (#2298, #2299, #2301, #2305, #2308) with them: the
floor is about 257. 2.6's census landed (#2311); M1 is measured once
4.5's item 2 lands, since it changes what a main push costs.

What stage 2 showed, beyond its numbers:

- A root run hides a nested-sandbox failure (3.0a).
- `tool` grants three things under one name (3.0b).
- The harness's bytecode matched across every leg, so the guard's
  digest holds it without a false failure.
- Each harness edit rewrites one `acknowledged` line, a merge conflict
  between concurrent PRs (3.0a).

### 2.2 Key tests by a harness epoch: landed (#2295)

- The declared key holds `epoch` (`build/harness_epoch.tl`) and
  `timeout` in place of the harness's source and bytecode.
- `build/harness_epoch_test.tl` holds the harness set (what a worker
  loads, `harness_own`, the key's own code, by source and bytecode) to
  an acknowledged digest. It also fails when a harness module requires
  one outside the set.
- A merge-queue run whose change moves `build/harness_epoch.tl` runs
  `--all`.
- Shows: a comment in `build/test.tl` reran 597 of 2020 tests (all
  before), and one in `build/zig.tl` or `cosmic/http.tl` only their
  importers.
- Left: the sandbox's plan keyed as data (`build/test.tl`'s `TODO:`
  above `harness_own`).

### 2.3 Stand-in built once per run: landed (#2296)

- `stand_in.build` writes the probe's carried rows to a small
  database and appends it to this program's core, in-process. It
  starts nothing, so its tests need no `tool`.
- `stand_in.build` fell from about 500 ms to 35 ms (release) and from
  2.5 s to 0.45 s (checked). The 15 affected modules, run `--all`,
  took 17.6 s instead of 45.2 s (release) and 84 s instead of 181 s
  (checked).
- `tool` fell to 312 tests from 455.
- A test that confines a process in a root of its own keeps `tool`: a
  worker without it runs under Landlock, which refuses the mounts a
  nested sandbox is built from (`build/confine.tl`'s `TODO:`).
- The isolation test still takes about 7 s. That is its two nested
  runs, not the stand-in.

### 2.4 Tool and store floor, batch 2, and tree-wide checks out of the suite

Batch 1 (#2283) took 245 tests off `tool`/`store`, and 2.3 took 143
more. After 2.3 the floor was 348 (300 `tool`, 48 `store`), so the
old target of about 355 was already met. The new target is at most
275.

- Rule R6: only a test of one module may read the store. A check over
  the whole tree is not a unit test: it runs in `fix --check .`, from
  `build/tree_checks.tl`. A module left with `store` says why.
- A test keeps `tool` if it starts or reads this program, reads the
  store beyond its closure, or nests a sandbox (see 2.3).
- PRs:
  - A, landed (#2298): tree-wide checks into `fix --check .`
    (exports, doc anchors, compiler readers, command stand-ins, docs
    queries, `quieted` names). `store` fell from 50 tests to 29.
  - C, landed (#2299): eight clean `tool` splits, 35 tests.
  - D, landed (#2301): `standalone`, `refresh` and `embed`, 17 tests.
    `embed` freed only 3 of 13: writing an executable copies the
    store's rows.
  - B, landed (#2305): store seams (`errors`, `fix.notes`,
    `invoke`, `core/declarations`), 10 tests.
  - F, landed (#2308): ten more modules split, 22 tests. The floor is
    about 257, under the target.
  - E, deferred: the store's lookup through attached databases
    (`core/store.c:809`). It needs a binding, an export and an epoch
    bump to free one test.
- Shows: the floor, by the named `o/bin/cosmic sql` query over
  `test_inputs`, at or under 275.

### 2.5 Key precision, smaller: landed in part (#2294)

- The writer identity is built from roots, with a guard like the
  compiler's.
- A commit that moves both the fingerprint's definition and an
  identity settles once instead of refusing.
- Left: the compiler identity is still wider than what shapes a
  compile (`build/work.tl`); a test that starts a process keeps no
  verdict until its second run (`build/test.tl`). Both stay `TODO:`s.

### 2.6 Measure M1

- Change: `ci/cosmic_ci/report.tl:257` (S). `cosmic test --census`
  names the key parts of the rows it restored, so `report` qualifies a
  run by the restored cache's parts, not the previous run's.
- Then take M1 over the next ten ordinary merges. Without `gh` in this
  container, the run data comes through the GitHub API tools.
- Shows: M1's four numbers, recorded above.

### 2.7 Every worker loads less

The harness set (`build/harness_epoch.tl`, 44 modules) is what every
worker loads, `harness_own` and the key's own code. It includes most
of the standard library (`cosmic.time`, `codec`, `hash`, `stream`,
`fs`, `string`, `sqlite`, `store`), so an ordinary edit to one sends
the merge queue to `--all` (M1's second measurement: 6 of 13 runs).

- Change: census what `worker.loads` pulls in and why; load the
  judging and keying code without the modules a test imports for
  itself, which its own key already holds.
- Shows: the harness set's size, and the share of gating runs that go
  `--all`, both lower.
- Census (2026-09-29): the set has 45 modules, mostly because
  `key_code`'s walk follows `local type` requires (the `imports` table
  does not mark them) and every worker loads `build.declared_key` for
  three helpers. A worker loads exactly `worker.loads`; it never loads
  `cosmic.child`, `stream`, `compress`, the analyzer or `build.ast.*`.
- Rule: the set is the value-require closure of the three roots, and
  harness code reaches `cosmic.*` only through a named library list
  (`fs`, `env`, `proc`, `sqlite`, `string`, `test`, `coverage`,
  `removed`), which a test holds. Hashing the key code's library
  closure into every key was rejected: it reruns everything on each
  edit, locally too.
- PRs, all acknowledged, none bumping the epoch (each keeps the same
  keys, and tests that):
  1. The worker off `declared_key`, `time`, `store` and `log`
     (`build.key_parts`). After the stage 3 batch, which edits
     `filesystem_observations.tl` and `declared_key.tl`.
  2. `build.digest` as a raw module in `core/store.c` (moves the core).
  3. The value-only walk, the sandbox probe out of `harness_own`,
     `cosmic.test` off `cosmic.errors`, and the library-list test.
     After stage 3.
  - Later (2.7b): hold only the key part of `build.test`, the
    most-edited module left.
- Expected: 45 modules to 27; of the last 40 main commits, the share
  that sends the queue to `--all` from 45% to 20%, and among
  ordinary PRs from 10 of 34 to 2.

### 2.8 A closure store carries only its closure's declarations

Every closure store carries every `*.d.tl` whole
(`build/closure_store.tl`), and a test's key holds its store's
address, so an edit to any declaration reruns every test (#2327:
2216 of 2216).

- Change: a store carries the declarations its closure reads.
- Shows: an edit to `cosmic/internal/store.d.tl` reruns only the tests
  whose closure holds `cosmic.store`.

### Milestone M2

These use the local probes (see Measuring):

- The tool/store floor is at most 275. Once met, it leaves the
  milestones: the tests left on `tool` start the program, and what an
  edit reruns is measured by the probes below.
- A comment in `cosmic/shape.tl` reruns at most 400 tests (582 before).
- A comment in `build/zig.tl`, `cosmic/http.tl` or `build/test.tl`
  reruns at most 400. Each reran every test before.
- Over the ten gating runs after M2, whatever their digests, the median
  run's checked suite stands on at least 70% of its tests.

## Stage 3: soundness, before declared keys widen (one to two weeks)

Each gap here can leave a verdict standing that a rerun would fail. An
audit of main after stages 0 and 1 (2026-09-28) re-checked every item;
line numbers are on main at 93a6bba.

**Rule:** a fix that tightens a hold or a bind without adding a key
part bumps the harness epoch (2.2). Otherwise verdicts earned through
the hole stand until the merge queue's `--all` or the nightly run.
Holes shaped by the host (3.1 items 8 and 9, and the kernel at
`build/declared_key.tl:1047`) are never caught by CI's `--all`, which
runs only CI's images. Each is fixed, or accepted in writing here, not
left to that backstop.

**Batching:** each epoch bump reruns every test once in the queue
(about 15 min and 80 runner-minutes). The items that tighten what a
test may do (3.0c's R1 to R3 and R5, 3.1 item 1, and 3.0b) land under
one bump: in one PR, or in PRs merged together with the bump in the
last.

### 3.0a Before the rules

- **A test that returns early is counted as skipped (S–M).** A test
  that nests a sandbox returns before asserting where the host cannot
  nest (as root). A root run then reports it passed, which is how
  2.3's failure reached CI unseen by every local and agent run.
  - Change: a skipped verdict in `build/test.tl`'s tally, and the
    sandbox tests report it (`core/syscalls_test.tl:56`,
    `core/syscalls_tool_test.tl`'s copy).
  - Shows: a root run says how many it skipped; a run held to the
    sandbox fails on any.
- **Unprivileged runs before a push (process).** A change that drops
  or narrows a declaration runs its changed modules as an unprivileged
  user (`COSMIC_SANDBOX=must`), with the tree copied to a directory
  that user owns. This goes in the ship skill
  (`.claude/skills/ship/SKILL.md`).
- **`acknowledged` per module (S): in review.** `build/harness_epoch.tl` holds one
  digest over every harness module, so two PRs that each touch one
  conflict on the same line (it happened twice in stage 2). Holding a
  digest per module lets them merge. The guard's message and the
  epoch rule stay as they are.

### 3.0b `tool` means one thing

`tool` grants three things: starting this program, lifting the store
hold, and leaving the worker outside the Landlock execute ruleset so
it can nest a sandbox (2.3). A declaration that grants what a test does
not need is a hole the key does not show.

- Change: `nests = true` for a test that confines a process in a root
  of its own (`build/confine.tl:438`'s `TODO:`). `tool` no longer
  lifts the store hold: a test that reads the store beyond its closure
  declares `store`. This takes in 3.1 item 5.
- Lands under the batched bump above.
- Shows: `--audit` names a `tool` test that reads the store, or a
  test that nests without `nests`.

### 3.0c Rules instead of keys

Where a rule removes a hole at little cost, the plan takes the rule
over a key that tracks the hole. Each rule is stated in AGENTS.md
beside `Test.needs`, and refused by the analyzer or the sandbox where
that is cheap.

- **R1. No real network.** A test may reach loopback only. This holds
  for every project, not just this tree: `cosmic.test` is public, and a
  project whose tests declare a real host or `network = true` is
  refused, with a message naming the rule (decided 2026-09-29; a
  breaking change, said so in the release notes).
  - No test but the harness's own tests of the mechanism declares
    another host.
  - Change: `Test.needs` refuses a network host other than loopback.
    The unkeyed path for such tests goes: they no longer run every time
    or get counted as unkeyed. The harness tests that used
    `example.com` test the refusal instead.
- **R2. Loopback is `127.0.0.1`.** `::1` is refused as a declared host.
  This replaces the IPv6 item: nothing keys the host's IPv6 sysctls.
- **R3. Host files, not host directories, except `/proc`.** A declared
  host path names a file, or `/proc`, which no key can hold by contents
  anyway. Real uses today are `/proc`, `/dev/urandom`, `/etc/localtime`
  and fixture-variable paths. This replaces walking a declared host
  directory; the analyzer refuses a directory.
- **R4. One `cosmic test` run per checkout at a time.** The rebuild lock
  from #2288 is held for the whole run, and a second run waits for the
  first.
  - This replaces the concurrent-runs item: the closure store and
    writer scratch-name races (`build/closure_store.tl:321`,
    `build/writer.tl:367`) cannot happen within a checkout.
  - A hand-run boot takes the same lock (`build/reboot.tl:312`).
  - 2.5 has landed, so this can start.
- **R5. No test depends on stat times** (item 1 below).
- 2.2 has landed, so R1 to R3 and R5 can start.

### 3.1 Holes, in order

1. **No test depends on stat times (S).** A key holds a file's
   contents, kind, size and mode, never its times, inode, device, link
   count or owner, which differ in every checkout. The rule: a test
   must not depend on those fields of a file it did not make. A test
   that needs them makes its own files in its temporary directory and
   sets them (`utimensat`, and a fresh file for a new inode).
   - Change:
     - Remove the `reads_stat_times` declaration
       (`build/filesystem_observations.tl`), the observed path's
       stat-time keying ("z"), and `cosmic/test.tl:33`'s part.
     - Rewrite its one user (`build/filesystem_observations_test.tl:1018`)
       to set the times it asserts on.
     - Replace `build/test.tl:608`'s TODO (infer the declaration) with
       the rule, stated in AGENTS.md beside `Test.needs`.
   - Enforcement, if cheap: under a worker's hold, `stat`, `lstat` and
     `fstat` of a path under the tree answer fixed times and inode. A
     test that leans on them then sees the same value in every checkout,
     rather than a value only some checkouts give.
   - 2.2 has landed, so this can start.
   - Shows: no module declares stat times, and the rule is in AGENTS.md.
2. **eval/ and test/portable not tool trees (S)** (`build/work.tl:540`).
   - Shows: an edit to `eval/summarize.tl` moves `boot_hash`.
3. **A module's file not in the local compile key (S)**
   (`build/importer.tl:1354`). `cosmic.removed` was already fixed by
   #2278.
   - Moves every local key once.
   - Shows: moving `x.tl` to `x/init.tl` recompiles.
4. **zig started while `declaring` runs, keyed by nothing (S–M)**
   (`build/confine.tl:833`, `build/filesystem_observations.tl:512`).
5. **A `tool` worker not held (M; with 3.0b)** (`build/test.tl:2057`,
   `can_forbid`). #2290 narrowed it to workers whose module declares
   the `bootstrap` cache.
   - Change: a cores directory the worker owns, bound by the sandbox.
   - Shows: a `bootstrap`-cache test that runs `o/bin/cosmic` is
     refused.
6. **The artifact's other ways in (M, C and a boot).**
   - A host program reads the artifact at `/proc/<worker>/fd/<n>`
     (`core/syscalls.c:474`; `PR_SET_DUMPABLE`).
   - A link can be swapped between the check and the call
     (`core/syscalls_fs.c:196`).
   - Shows: `sh -c 'cat /proc/$PPID/fd/<n>'` in a `system` test fails.
   - A host-program tree's database read by name (`build/confine.tl:400`)
     is out of scope: projects only.
7. **The program bound at its host path, for `tool` workers (M, C and a
    boot)** (`build/test_sandbox.tl:180`), with the mount-point race
    beside it (`build/test_sandbox.tl:265`, same `build_root` code).
    - Shows: a `tool` test's `Proc.executable()` is `/tree/o/bin/cosmic`.
8. **`/usr` changed outside a package (M, or accept)**
    (`build/declared_key.tl:1126`).
    - Change: a once-per-run walk, about 0.5 s, only when the run holds
      a `system` module.
    - Accepting it leaves developer hosts uncaught; say so here if
      chosen.
9. **The C check's verdicts don't hold the host's sh, sed, wc and tr
    (S)** (`build/c/init.tl:131`).

Accepted or out of scope:

- `access()` (`core/syscalls_fs.c:769`): the host identity now holds
  the uid, groups and capabilities, and the sandbox fixes the mount
  flags. Only ACLs remain. Reword the TODO and accept.
- `/proc/self/mountinfo` names each bind's host source
  (`build/test_sandbox.tl:190`). Only an adversarial test reads it.
  Accept, with a plain comment.
- The observed path's own gaps (`build/test.tl:531`, `:1116`) and
  `core/store.c`'s observe knobs (`:79`): they die with 4.2's PR 4 and
  PR 5.
- `core/store.c:809`, a missing feature, not a hole: it raises.
- `core/sqlite.c:721` (observed only) and `:601` (a future artifact
  layout).
- `build/test_worker.tl:343`: the standard library outside the closure
  in a project tree, releases only.
- `build/test_worker.tl:436`, `boot_hash` let through a hold: sound on
  the `tree_wide_meta` argument (#2293's review). Roadmap.

### 3.2 Platform-only code on macOS

- Decision: the macOS leg's scheduled run stays `--all`, and is the
  backstop.
- Change: a hand-maintained list of test modules that exercise a
  darwin branch, with a test that the list's modules exist. The macOS
  leg's gating run stands on nothing for those. The evidence for the
  list: darwin and aarch64 C is neither sanitized nor checked by `fix`
  (`ci/cosmic_ci/orchestration.tl:540`, `build/c/init.tl:80`).
- Before 4.2's PR 3, the unenforced worker gets:
  - the tree at a fixed path, or a key that holds the path
    (`build/test.tl:2651`);
  - its closure store rather than the whole projection
    (`build/test.tl:2658`; waits on `cosmic test --worker` taking
    `--store`).
- macOS strays (`build/test.tl:2767`).
- Shows: the list exists and is held by its test. A macOS gating run's
  row shows those modules ran.

### Milestone M3

- Every item in 3.1 has either landed, with a test that tries the
  hole, or is written up above as accepted.
- Each fix that moved no key part bumped the epoch.
- 3.2's list and its two worker changes have landed.

## Stage 4: fewer paths, less code (two to three weeks)

### 4.0 Move the driver pin

A bump to any `next-` prerelease after 165d091 (#2279) unblocks
`ci/cosmic_ci/orchestration.tl:409` now. 4.1 needs it. The rest of the
pin-gated TODOs still wait on features not on main: `build/zig.tl:380`,
`:413`, `:528` and `:892`, `ci/cosmic_ci/images.tl:136`,
`ci/cosmic_ci/fuzz.tl:210` and `ci/run-local:2`.
`o/bin/cosmic todos '"cosmic-driver.pin"'` lists them when the pin
moves.

### 4.1 Fixtures sandboxed, sharing verdicts

The `fixtures-sandboxed` branch never reached origin, so this starts
fresh. There are now 8 fixtures, including #2288's `self_rebuild_test`.

- Each fixture declares what it reads with `Test.needs`, naming host
  paths by the variable that holds them (`$COSMIC_FIXTURE_PRODUCT`,
  #2279).
- The runtime directory gets copies of `tool.tl`'s closure and the
  focused-embed build, with cores made executable at setup.
- The driver unpacks `work/portable-source.tar` as
  `COSMIC_FIXTURE_SOURCE`.
- Inner `cosmic test` runs get `COSMIC_TEST_SANDBOX=0`.
- `format`, `self_rebuild_test` and `fixed_point` stay unsandboxed:
  they write a checkout and compile cold.
- The launcher's noexec case moves to an unsandboxed module of its own,
  with a `TODO:`.
- `Orchestration.fixture` writes `fixtures.db` beside `verdicts.db`.
- The fixtures' 33-module project is compiled once per leg, not once
  per fixture (2.2 s each).
- Lower the fixtures' bounds (`ci/cosmic_ci/orchestration.tl:330`,
  `:350`).
- Waits on: 4.0, and stage 3.
- Shows: runtime, launcher, identity and product stand on a commit that
  moves neither the product nor the fixtures, taking 25 to 40 s a leg
  (about 2 min before).

### 4.2 Observation removal, PRs 2 to 5

- PR 2: `--audit` from the sandbox's refusals
  (`build/test.tl:3385`'s precondition).
- PR 3: declared keys become the default for every unsandboxed run,
  retiring `COSMIC_TEST_KEY` (8 files). Such a run shares only when
  `COSMIC_VERDICT_CACHE` names a file.
  - Waits on: PR 2, 4.1, M3, and 3.2's two worker changes.
  - Closes `build/test.tl:3385`.
- PR 4: delete the observed key path, the `reads` column of `runs`,
  `Test.needs.processes`, and the worker's logging. About 2,500 lines
  of Teal.
  - Closes `build/test.tl:531`, `:837`, `:955`, `:1024` and `:1116`;
    `build/confine.tl:66`, `:343` and `:697`;
    `build/filesystem_observations.tl:35`, `:407`, `:701` and `:899`;
    `build/test_worker.tl:155` and `:186`; `core/sqlite.c:721`.
  - `build/test_worker.tl:186` is the report capture limit. Closing it
    also unblocks `fuzz.yml:70`'s 10,000 iterations.
- PR 5: delete `core/observed.c` and its hooks, the observed SQLite
  VFS, and `core/store.c`'s observe knobs. About 1,900 lines of C.
  - Closes `core/observed.c:81` and `:325`, `build/confine_test.tl:193`,
    `build/filesystem_observations.tl:146` and `core/store.c:79`.
- Measure before PR 4 and after PR 5, with the local recipe.

### 4.3 One SQLite module for the shared caches

Still three copies of the WAL, busy_timeout and corrupt/set-aside code:
`build/shared_compiles.tl:335–406`, `build/shared_verdicts.tl:195–229`
and `ci/cosmic_ci/cache_trim.tl:63–243`. #2291 already added the
content digest, so that half of the item is done.

- Change: the build modules share one module.
- Change: `cache_trim.tl` calls the tool's own trim verb by running
  `o/bin/cosmic`, as its `TODO:` at `:108` says. ci/ runs on the pinned
  release, so it cannot `require` a new build module until the pin
  carries it.
- Waits on: nothing. This is maintainability.

### 4.4 CI and build speed, smaller

- The zig build cache grows on runs whose inputs match what they
  restored (`.github/workflows/ci.yml:396`, `:425`): save only what
  changed, or bound it.
- `fuzz.yml` restores the zig cache (`:130`, S), and its job is
  sandboxed (`:46`, `:120`, S–M).
- The boot recompiles its closure, about 3.6 s (`core/bridge.lua:154`,
  `:186`).
- The CI driver check runs sandboxed (`ci.yml:642`; pin-gated, with
  4.0).

### 4.5 CI flow

A measurement of 28 runs (2026-09-28, main at 5900ce68) found most of
CI's cost outside the suite's verdicts. It waits on nothing, so it runs
alongside stage 3; the items touch `ci.yml` and
`ci/cosmic_ci/orchestration.tl`, so they land one at a time.

- A landed change costs about 65 runner-minutes. The queue run takes
  33 to 39 (11 to 13 min wall), and the main push repeats the full
  scope on the SHA the queue just passed: 26 to 30 more, in 41 of 42
  pushes. Pending main runs get cancelled, and those commits save no
  caches.
- The queue restores main's newest save, usually several commits
  behind. For the same SHAs, its suites ran 823 to 884 tests against
  main's 395 to 658, its boot missed the compiles cache every time, and
  its checked suite took 205 to 250 s against main's 104 to 137.
- linux-x86_64 is the long pole at 690 s against 470. The whole gap is
  the checked suite.
- Fixtures take 135 to 210 s a leg and never stand; self-rebuild alone
  is 50 to 123 s on every leg.
- A branch whose base is behind main's newest save reruns everything.

Items, in order:

1. **ci.yml cleanup (S; no time saved): landed (#2309).** One expression for "this run
   saves" and one for the scope, in place of the three copies
   (`ci.yml:750`, `:763`, `:943`, `:959`, and `:142`, `:987`). History
   and measurement comments move out, leaving one or two lines a step:
   under 450 lines, from 1038. `retention-days: 7` on the product and
   driver uploads.
   - Shows: `build/workflows_test.tl` passes, and a main run saves as
     before.
2. **Main reuses the queue's result (M): landed (#2320).** Its own
   main push (run 36507253271) took 47 s against 8 to 10 min: `reuse`
   found the queue run in a second, the four seed legs saved its
   verdicts, compiles and driver marker, and the prerelease published. The queue uploads each leg's
   trimmed verdicts and compiles, with the keys it computed, as
   `seed-<leg>`. A main push first looks for a successful `merge_group`
   run of `ci.yml` with the same `head_sha`. Finding one, it skips
   `platform`: a `seed` job per leg, on that leg's runner, saves the
   seed under its keys, and `ci` re-uploads the queue's products, so
   `prerelease.yml` is unchanged. Any other push, dispatch or schedule
   runs the full scope as today.
   - Risks: a flake the second run might have caught; the nightly full
     run stays. A wrong seed costs stands, never correctness: each row
     is keyed by its own inputs.
   - Shows: main runs under 2 min with none cancelled; runner-minutes
     per landed change from about 65 to about 38; the queue's suites
     stand more (its restores one commit behind).
3. **The checked suite in its own gating job (M): next.** M1's second
   measurement: linux-x86_64 is the gate in 9 of 13 runs, its checked
   suite 178 to 345 s. Standing more does not shorten it much (the
   tests left to run are the slow ones).
   Re-measure after item 2. If linux-x86_64 still runs more than a
   minute over the other legs, the checked suite moves to a job of its
   own (a native-suite skip on the build, then `platform checked`).
   - Shows: the median queue run at 8 min or less.
4. **Fixtures compile their project once per leg (S),** through one
   `COSMIC_BUILD_CACHE` in the work directory (`orchestration.tl:489`).
   This is 4.1's bullet, done without sandboxing. About 20 s a leg.
5. **Self-rebuild on two legs in gating runs (S–M):** linux-x86_64 and
   macOS, every leg in the scheduled run, as the fixed-point
   regression does (`COSMIC_CI_SELF_REBUILD`). About 3 runner-minutes a
   full run.
6. **No tree put-back around the cache saves (S–M).** Keep
   `$GITHUB_WORKSPACE` a directory and link only the working directory
   into the moved tree, so `ci.yml:738` and `:773` go.
7. **A branch restores from its merge base (M).** Main's saves also
   take a key by SHA, kept a day or two; a branch run looks up
   `git merge-base HEAD origin/main`'s key first, then the newest.
   - Shows: a branch five commits behind main stands on verdicts.
8. **The portable suite narrowed:** re-decided after item 2, with its
   numbers.

Expected after items 2 to 5: the queue about 8 min wall and 34
runner-minutes, main about 1.5 min and 4, about 38 per landed change.

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

- **To roadmap.md, from the TODO sweep:**
  - musl's `comp_dir` reproducibility (`build.zig:151`,
    `ci/cosmic_ci/orchestration.tl:504`): no key moves.
  - flock (`build/reboot.tl:309`, `build/patch.tl:398`,
    `build/zig.tl:220`): waits on a `cosmic.sys` binding.
  - Key precision for the image and the kernel
    (`build/declared_key.tl:1042`, `:1047`, `:382`).
  - `build/reboot.tl:84`, `build/confine.tl:557` and `:563`,
    `core/syscalls.c:921`, `build/dispatch.tl:314`,
    `build/refresh.tl:592`, `build/doctest/generate.tl:262` and
    `build/sandboxed_verdicts_test.tl:295`.
  - `cosmic/child_test`'s 45 `-e` children run on a Lua-chunk
    stand-in rather than this program, taking them off `tool`.
- **The checked suite in its own job** (was 2.3): dropped, then
  brought back conditionally as 4.5's item 3. The queue's checked suite
  does not stand while its restores lag main.
- **Narrowing the key code's closure** (was 2.2 (a) to (d)):
  superseded by the harness epoch (2.2).
- **Report a red scheduled run, and pull its verdict:** dropped. The
  `TODO:` on ci.yml's `schedule` stays.
- **Portable suite narrowed** to the tests that depend on the artifact:
  deferred to 4.5's item 8. Measured, it repeats the native suite's
  set every run (50 to 108 s a leg).
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
- **Stage 2** (2026-09-28): 2.2 harness epoch (#2295), 2.3 stand-in
  in-process (#2296), 2.5 writer identity and one settle (#2294).
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
