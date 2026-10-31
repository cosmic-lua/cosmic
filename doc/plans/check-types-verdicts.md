# Verdicts for checked runs

`cosmic test --check-types` (a checked run) stands on no verdict: it runs every
test, every time. CI's `checked-narrowing` job makes one on every full run. This
plan lets a checked run stand on a verdict that an earlier checked run earned under
exactly the same key, so that job runs only the tests whose checked key moved. It is a
proposal: nothing here is built.

Figures are marked **measured** (run on this tree at `40109d046`, on an x86_64
Linux box with 4 cores) or **estimated**. Line references are to that commit.

A *checked run* is `cosmic test --check-types`: the tree compiled with run-time
checks. It is not the *checked core*, the sanitized core that CI's `checked` and
`checked-shard` jobs run the suite on, whose verdicts live in `checked.db`.

## What a checked run does now

A checked run compiles the tree with run-time checks into a projection of its own
(`cosmic.checked.db`, [`build.test`] at `build/test.tl:1493`), keys the compile apart
from an unchecked one ([`importer.checked_tool`], `build/importer.tl:1407`), starts each
worker with `COSMIC_TEST_TYPES=1` (`build/test_worker.tl:1128`), which installs the
hooks the checks call (`worker.install_checks`, `build/test_worker.tl:1432`), and ends
with what the workers reported (`say_violations`, `build/test.tl:2205`).

It runs every test because the lookup is told to:

```text
-- build/test_key.tl:2032
local force: boolean = forced == true or rec.checks
```

The reason is stated beside it (`build/test_key.tl:2010`): "a verdict that stands runs no
worker, and a worker is what reports". The module doc of [`build.test`]
(`build/test.tl:92`) and [`doc/testing.md`] ("run-time type checks") say it too. Two things
come only from a worker:

- the violation rows (`take_violations`, `build/test.tl:844`, called only
  `if rec.checks`), which fill the `run-time types:` summary and the
  `type_violations` table, and make the run fail for a parameter violation under
  `cosmic/` that a `pcall` swallowed (`library_violation`, `build/test.tl:2186`);
- the C functions the test entered, for the run's check that some test enters each
  (`settle`, `build/test.tl:2285`).

A fact that is false needs no report: it raises in the worker, and the test fails
([`doc/testing.md`], "checked narrowing").

The run is not without verdicts. It keeps one for every pass under a key of its own
and never reads it back. **Measured:** a checked and then an ordinary run of
[`cosmic/json_test.tl`] into one empty `COSMIC_VERDICT_CACHE` left 118 rows for its 59
tests, 59 under each mode.

### What it costs

CI (**measured**, runs of 2026-10-23, [`ci/README.md`], "the checked jobs"): 150 to 195 s
to boot, 726 to 861 s for the suite and 10 s to finish, 890 to 1070 s in all, on a
runner of its own.

Here (**measured**, `COSMIC_TEST_TIMEOUT=120 bin/cosmic test --check-types`, compile
cached): 7852 tests keyed in 8.5 s; 7855 ran, 0 stood, 140 skipped and 64 were n/a, in 831 s
(1682 s summed over the workers). The compile of the tree with checks takes 66 s when
nothing is cached and 1 s when everything is. The run reported 822 violations at 91
distinct rows (62 `field`, 22 `fact`, 7 `parameter`), and its C check passed (630 of 630
functions entered).

## Why a checked run's outcome differs

What a verdict has to stand for is what a worker can see. A checked worker differs from
an ordinary one in six ways. The key holds three of them today, by accident of the
bytes rather than by name.

| Difference | Where | In a key today |
| --- | --- | --- |
| The Lua of every module of the closure carries `__fact` calls at narrowed reads ([`lang.fact_wraps`]) and `__cosmic_tc` calls at typed parameters ([`lang.boundary_checks`]) | the checked projection, read by `rec.projection` (`build/test_key.tl:1859`) | yes: the closure store digests each module's bytecode (`build/closure_store.tl:275`) |
| The hooks, and what they raise and record | `worker.install_checks`, [`worker.fact`] in [`build.test_worker`] | by the harness epoch, as all harness code is |
| Code that asks whether the hooks exist | [`build.fuzz`] allows four times the instruction budget (`build/fuzz/init.tl:76`); [`build.type_watch`] `checked` | no: only the bytes of the closure, which differ in practice |
| What the run reports and fails | `take_violations`, `library_violation`, `say_violations` in [`build.test`] | no: a standing verdict reports nothing |
| Tests that skip | three that compare bytecode with the binary's, and the declared-types tests ([`doc/testing.md`]) | a skip keeps no verdict |
| The compiler name, for a test that reads the compiler | `rec.compiler` (`build/test_key.tl:1866`) | yes, for those tests alone (`reads_compiler`, `build/key_parts.tl:121`) |

Nothing names the mode. The existing test
`test_a_checked_runs_verdicts_never_stand_for_an_unchecked_run`
(`build/sandboxed_verdicts_test.tl:658`) shows it: a test whose closure compiles to the same
bytes in both modes "stands across the two", and an unchecked run stands on a checked
run's pass. That is sound while the bytes are the only difference, and the table shows
they are not (the fuzz budget).

## What the key must hold

A checked verdict is: this test, given this checked closure, these declared inputs, this
core, this harness and this mode, passed with the hooks installed and met no violation.
Each part, and why:

| Part | Holds | Why | State |
| --- | --- | --- | --- |
| `m` | the graph key of the module | the sources the closure follows from | held |
| `runtime`, `host` | the core, the data tables, the kernel and processor features | the checked job runs the release tool, not the sanitized core (`release_promises`, `ci/cosmic_ci/orchestration.tl:1693`) | held |
| `epoch` | the harness epoch ([`build.harness_epoch`]) | the hooks and the judge are harness code | held |
| `timeout` | the worker's timeout | a pass in 120 s is no pass in 30 s | held |
| declaration, `requires`, files, env, `system`, `launcher`, `program`, `tree` | what the test declares | as for any test | held |
| closure store | the bytes of the checked projection of the closure | **the checks are in it**; see below | held |
| `checks` | the format of the checks the compile writes | the mode, by name | **new** |

### The closure store holds the checks

A worker runs the Lua of its closure, and nothing else of the tree. The store a worker is
given is cut from the projection the run compiled (`rec.projection = from.database`,
`build/test_key.tl:1859`; the checked run's is `cosmic.checked.db`), and a test's key holds
the digest of its bytes, which include each module's bytecode
(`build/closure_store.tl:275`). So the key already moves when anything the checker or
code generator does changes the checked Lua of a module the test loads, and does not move
when it changes the Lua of one it does not. A module the tool carries and the closure
does not hold fails its test (`unkeyed`, `build/test_worker.tl:1225`), so the closure is
all a worker runs.

This is the precise key. Holding the compiler's or the checker's identity in its place
would be worse in both directions:

- [`build.identity`]'s compiler identity leaves `lang/` out on purpose
  (`build/identity.tl:551`); the code of the checker is named by `pipeline.coded`, which a
  test key does not hold. Holding it in every key would rerun every test on each edit to
  `lang/`: 14 of the last 60 commits on main (**measured**) edited a non-test file of
  `lang/` or the pipeline. Of 738 test and example modules, 143 hold [`lang.check`] in their
  closure, 142 [`lang.codegen`], 139 [`lang.fact_wraps`] and 110 [`lang.boundary_checks`]
  (**measured**, `imports` and `decl_imports` of the projection).
- The digest moves a test's key when the checked Lua it loads changes, and an edit to
  [`lang.check`] changes that Lua only in the modules whose narrowing it moves, not in
  all 143 test modules that hold the checker in their closure.

### The `checks` part

The mode goes in by name, so that two keys cannot be equal across modes whatever the bytes
are. [`build.declared_key`]'s `Spec` gains a field `checks`: `nil` for an ordinary run,
and for a checked run the format token `importer.checks_format`, which names what the
compile writes. The preimage holds it as `part("checks", ...)` only when it is set, so no
ordinary key changes (`build/declared_key.tl:869`). The token is the suffix that
[`importer.checked_tool`] hashes into the compile keys now (`"fact-wraps"`,
`"parameter-checks"`), made one constant that both use; a check added later (returns,
fields) moves it, as it moves the compile keys.

The census names it (`--census`, [`shared_verdicts.named`]) so that a run whose rows all
moved says it was the mode. The part is not for staleness, which the bytes cover. It is for two things they do not:
a closure whose bytes are equal in both modes, and a test that reads the hooks (the fuzz
budget). `declared_key_test.tl` already holds every field of a `Spec` to moving the key,
so the new field has a test the moment it is added.

### What is not a part

- **Promises.** A held run fails a module for an n/a or a skip of a requirement its leg
  promises. The host is asked once, for every requirement of the selected modules, before
  any worker starts (`build/test.tl:1873`), so a standing verdict hides none of it. The
  answers are in the key (`requires`). The narrowing job takes `checked` out of the
  promises (`release_promises`) and its `requires = { "checked" }` modules are n/a, as
  now.
- **Violations.** They are not an input; they are an outcome, which decides whether a
  verdict is kept (below).

## Which verdicts are kept

A pass is kept under its checked key only when all hold:

1. the test passed, asserted, and did not skip (as for an ordinary verdict);
2. its worker reported that the hooks were installed;
3. its worker reported no violation row of any kind, and no dropped row.

(2) closes a hole the key cannot: a worker of a checked run that installed no hooks
passes having checked nothing, and its verdict would stand for every later run of those
bytes. [`build.test_worker`]'s report gains `checked?: boolean`, set by
`install_checks`, and [`worker.judge`] fails a report that lacks it when the run is
checked (`Judging` gains `checks`). The message names the cause.

(3) keeps the report complete. A test that met a violation (a `parameter` row outside
`cosmic/` that the run only reports, a `fact` row a `pcall` swallowed, a `cosmic/`
parameter a `pcall` swallowed) keeps no verdict, so it runs again in every checked run
and reports it again. Every violation the tree has is therefore in every run's report and
in `type_violations`, whatever stood, as long as a test behaves the same each time it
runs with the same key, which the whole verdict scheme assumes. A pass that meets a
violation where a row stood under its key is dealt with as a failure is: the row goes
from the working database and from the shared cache ([`test_key.keep`],
`build/test_key.tl:2171`, and `owed.failed`), so the next run does not stand on it.

The cost is the tests that meet a violation, which run in every checked run. **Measured:**
in the run above, `type_violations` names 17 tests, all of them tests of the hooks and the
boundary code ([`build.fact_hook_test`], [`build.boundary_hook_test`], [`lang.boundaries_test`],
[`lang.boundaries_fuzz_test`], [`build.type_violations_test`]) that plant violations on
purpose. They took 7.1 s of the 1682 s. The table names only the first test to meet
each row, so 17 is a lower bound; the first runs under the plan show the rest.

## Storage

A checked run reads and writes a verdict file of its own, so that the two modes do not
share the bound. [`build.shared_verdicts`] keeps at most 8192 rows a file
(`kept_rows`, `build/shared_verdicts.tl:108`) and the suite has 7852 tests: a second set of
keys in the same file would evict the first at every save.

- Locally, [`shared_verdicts.location`] answers `verdicts/verdicts-checked.db` beside
  `verdicts.db` for a checked run that names no `COSMIC_VERDICT_CACHE`. A run that names
  one uses it, as now. The key part, not the file, keeps the modes apart; the file keeps
  the bound.
- In CI, `Orchestration.suite_verdicts(env, "narrowing")` names `narrowing.db` beside the
  job's `verdicts.db`, as `checked.db` is the checked suite's
  (`ci/cosmic_ci/orchestration.tl:425`). The job restores, trims and saves a directory
  that holds that file alone. The driver's `verdicts-trim` and `verdicts-merge` take any
  `.db` in the directory (`ci/cosmic_ci/verdicts.tl:53`).
- The working database's `verdicts` table holds both modes, its keys being disjoint. The
  closure stores a checked run writes are addressed by the checked projection, so they
  do not collide with an ordinary run's either; the `stores_v1` table of the checked file
  holds their digests.

A checkout that alternates modes sweeps the other mode's closure stores
(`sweep_stores`, `build/test_key.tl:1093`). A run that stands writes none: it takes each
store's digest from the `stores_v1` table of its own file, so neither mode rewrites the
other's stores for a run that stands.

`--all` and `--no-shared` mean what they mean. `--check-types --all` runs every test,
which is what the nightly and a merge that moves the harness do.

## CI

The job `checked-narrowing` gains what the checked suite's jobs have, in the same steps,
under its own name. The edits to [`.github/workflows/ci.yml`]:

1. **Name the host and its cache.** `leg-host-id` is called with `linux-x86_64-checked`
   today. The `checked` job calls it with that name too, so the narrowing job's cache
   would be the checked job's. Call it with `linux-x86_64-checked-narrowing`: the same
   image and engine give the same `COSMIC_HOST_ID`, and only the cache prefix differs
   (`ci/cosmic_ci/host_id.tl:207`). A prefix by hash cannot match the other's: the name is
   followed by 16 hex digits, and `n` is not one.
   `COSMIC_WORKER` stays `linux-x86_64-checked`: it picks the leg's promises, not the cache.
2. **Restore.** Look up the entry of the tree's base on main and restore it, as the legs
   do (`verdicts-base-lookup`, `verdicts-base`, `verdicts-restore`).
3. **Run ahead.** In the merge queue, find the run ahead (`queue-ahead`) and merge its
   `verdicts-linux-x86_64-checked-narrowing` artifact, as a share does, so an entry
   stacked on another starts from the other's rows. The wait is the share's: 90 s at most,
   and none for a run ahead that has not kept its verdicts yet (`READY_SECONDS`, to be set
   from the first runs: a share's is 600).
4. **Run.** `phase_checked_narrowing` builds its line from `Orchestration.suite_run`'s
   words and names the file, instead of the fixed `test --check-types`
   (`ci/cosmic_ci/orchestration.tl:1687`):

   ```text
   local run = Orchestration.suite_run({
     COSMIC_VERDICT_CACHE = Orchestration.suite_verdicts(Env.all(), "narrowing"),
     COSMIC_TEST_TIMEOUT = checked_narrowing_test_timeout_s })
   -- run.words is { "test", [--all], [--bail] }; add --check-types and --census.
   ```

   `Orchestration.stands` then decides as for every suite: a push and the merge queue stand
   on verdicts, and main's scheduled run, a manual run, and a queue run whose change moves
   [`build/harness_epoch.tl`] run every test (`--all`, nothing shared).
5. **Trim, keep, save.** `verdicts-trim` after the run, the artifact for the run behind,
   and the cache save on `COSMIC_CI_SAVES` under the job's prefix, with the entry
   under the commit and its `seed`, `prune` and `invalidate` entries; the lists in those jobs
   (`needs`; `LEGS`, which `queue-find` reads, `ci/cosmic_ci/queue_seed.tl:255`) gain the job.

The scheduled run saves, so main's newest entry is the nightly's `--all` run: a test that
passed in every earlier run and fails in this one takes its row out, and the entries
under a commit are invalidated when the run fails (`invalidate`), as for the legs.

The job stays one job. Splitting it into shares (the `TODO:` at `ci.yml:1880`) is not
needed for a run that is mostly standing, and the key is independent of any split.

## What only a whole run answers

Three things, each answered the way a leg answers it.

**C functions entered.** `settle` checks that some test enters each C function when the
run is of the whole tree (`ctx.whole`, `build/test.tl:2285`). A test that stands has its
hits credited from its row (`credit_hits`, `build/test.tl:432`), and the row of a checked
verdict holds the hits of the checked run that earned it, on the same core, since the core
is in its key. The ordinary legs make the same check the same way. A checked run with
`--bail` or a shard says "not checked", as they do.

**The `run-time types:` line.** `say_violations` prints it in every checked run
(`build/test.tl:2205`), and `phase_checked_narrowing` fails a run without it
(`ci/cosmic_ci/orchestration.tl:1699`). That guard says the flag was honored, but a run in
which every test stands also prints it, whether or not the compile carried checks. The
runner therefore counts, at the end, the modules of the checked projection whose
bytecode names `__fact` or `__cosmic_tc` (`runtime_checks_tool_test.tl:158` already reads
`__fact` from the file), and the line says `N of M modules carry checks`. The guard fails
on N of 0. With the hooks judged per worker, a run that has both is a checked run that
checked.

The line also says what stood: `K tests stood on checked verdicts`. Each of them held no
violation when it ran (rule 3 above), so the count of violations is the whole run's.

**The checked suite's gather.** The checked suite runs in four shares, none of which can
make the whole-run checks, then a gathering run that stands on all four shares' rows
(`COSMIC_CI_GATHER=1`, `checked_suite`, `ci/cosmic_ci/orchestration.tl:1135`). The narrowing job
is one whole run, so it needs no gather. If it is split later, its shares and a gathering
run work the same way over this key, which holds no share.

## Failure modes

| A verdict that stands wrongly | Prevented by | Caught by |
| --- | --- | --- |
| after a change to the checker or code generator that changes a module's checked Lua | the closure store digest holds the bytecode | `test_a_checked_verdict_moves_with_the_checked_bytecode` (item 3) |
| after a change to the hooks, the judge or the key code | the harness epoch ([`build.harness_epoch`]); an edit to a harness module fails `harness_epoch_test` until acknowledged | existing |
| for an ordinary run, or the reverse, where the bytes are equal | the `checks` part | `test_a_checked_key_is_not_an_unchecked_key` (item 1) |
| earned by a worker that installed no hooks | the report's `checked` flag, judged | `test_a_checked_run_fails_a_worker_that_installed_no_hooks` (item 6) |
| for a test that met a violation a `pcall` swallowed | no verdict with a row | `test_a_swallowed_violation_is_reported_by_every_run` (item 5) |
| after a fact check that depends on something undeclared | the key holds declarations and files; the sandbox denies the rest and `unkeyed` fails a test that ran a module no key holds; the nightly runs every test | as for any test |
| because the compile carried no checks | the count of modules that carry them, in the summary and the guard | `test_a_checked_run_that_carried_no_check_is_refused` (items 9, 10) |
| for a run on the sanitized core, or the reverse | the `runtime` part (another core image) and a file of its own | `test_a_checked_run_reads_its_own_file` (item 7) |
| after a timeout is raised | `timeout` is in the key | existing |

No key can close the row on a fact check that depends on something undeclared, and it
is the same for every suite: a test that reads something no key holds can pass once and
fail later, and a fact check is no more deterministic than the test it checks. The
nightly run is the backstop, and a pass that a later run of the same key finds violated
is taken out of the cache (above).

## Tests to add

Each fails if a verdict stood wrongly.

1. `build/declared_key_test.tl`: `test_a_checked_key_is_not_an_unchecked_key`: two
   specs equal in every field but `checks` make different keys, for a closure of equal
   bytes; and the new field is among those the existing test holds to moving the key.
2. [`build/sandboxed_verdicts_test.tl`], replacing the second half of
   `test_a_checked_runs_verdicts_never_stand_for_an_unchecked_run`: a plain run after a
   checked one runs both tests (`2 ran, 0 stood`) and so does a checked run after a plain
   one. Then the new rule: a second checked run is `0 ran, 2 stood` and reports the same
   coverage line as the first. `plain_test`'s closure compiles to the same bytes in both
   modes, so this fails without the `checks` part.
3. `build/sandboxed_verdicts_test.tl`: `test_a_checked_verdict_moves_with_the_checked_bytecode`:
   a module with a typed parameter and a narrowed read; a checked run, then an edit to
   a module outside the test's closure (it stands), then an edit to one inside (it runs).
   And at [`build/closure_store_test.tl`], the store of a closure compiled with `facts`
   digests differently from the same closure compiled without
   (`fact_hook_test.tl:160` compiles both). This is the test that fails if a later change
   cuts a store from the unchecked projection.
4. [`build/runtime_checks_tool_test.tl`], extending the test at line 123: after
   a checked run that reports one `parameter` violation in one of two tests, a second
   checked run says `1 ran, 1 stood`, reports the same violation again, and leaves the
   same row in `type_violations`. The current assertion `2 ran, 0 stood` ("a standing
   verdict hid a test from the report") becomes this one.
5. [`build/fact_hook_tool_test.tl`], beside `test_a_checked_run_reports_the_fact_that_is_false`,
   `test_a_swallowed_violation_is_reported_by_every_run`: a test that catches a false fact with `pcall` passes, keeps no verdict, and is
   reported by the second run too. The same for a `cosmic/` parameter under `pcall`: the
   second run fails as the first does (`library_violation`).
6. [`build/test_worker_test.tl`], `test_a_checked_run_fails_a_worker_that_installed_no_hooks`:
   [`worker.judge`] of a report that lacks `checked`, with
   `checks` set, fails and names the cause; with it unset, passes as now.
7. [`build/shared_verdicts_test.tl`], `test_a_checked_run_reads_its_own_file`: `location` answers `verdicts-checked.db` for a
   checked run with no variable, the variable's path when it is set, and `verdicts.db` for
   an ordinary run.
8. [`build/runtime_checks_tool_test.tl`], which runs unsandboxed: a pass that meets a violation where a verdict stood
   under its key takes the row out (`keep`, in the working database and in `owed.failed`).
   There a read the test does not declare works and moves no key: a test reads such a file and calls a function with a
   wrong kind when it holds `bad`. A checked run with the file `ok` keeps the pass; with
   the file `bad` and `--all` it reports the violation; the run after that, without
   `--all` and with `ok` again, runs the test.
9. [`ci/cosmic_ci/orchestration_test.tl`], beside
   `test_the_checked_narrowing_phase_runs_the_whole_suite_checked_on_linux_x86_64`
   (line 1766): the phase's argv holds `--check-types`, `--census`, and `--all` where the
   suite does not stand (the harness moved); its environment names `narrowing.db`; a
   `run-time types:` line that says `0 of N modules carry checks` fails the phase. And
   `ci_workflow` tests that the job has the restore, trim and save steps and the
   `narrowing` host name.
10. [`build/runtime_checks_tool_test.tl`], `test_a_checked_run_that_carried_no_check_is_refused`
    (the runner's half): a project whose modules have no typed parameter and no narrowed
    read says `0 of N modules carry checks`, and the phase's guard (item 9) fails on it.

## The harness epoch

The change touches four harness modules: [`build.test_key`], [`build.declared_key`],
[`build.shared_verdicts`] and [`build.test_worker`]. [`build.harness_epoch_test`] fails
until their digests are acknowledged. The change to a key is additive: an ordinary run
computes the keys it computes now, and a checked run's keys are new and read by nothing
yet. The judge's new failure is for a checked run alone. So the rule "a change that can
alter a pass or a fail bumps `epoch`" is not met for any verdict an earlier run kept, and
the plan acknowledges the digests and does not bump. The reviewer decides it; the cost of
the other choice is every suite running once on main.

Either way the merge queue's run for the change runs every test (`stands`: the file
moved), which includes a cold narrowing job, once.

Later edits follow the doc: an edit to `install_checks`, `fact` or the judge that can
alter a checked pass bumps `epoch`, and so reruns the ordinary suites too. Of the last
60 commits, none touched `lang/codegen`, `lang/fact_wraps`, `lang/boundary_checks` or
`build/test_worker` (**measured**).

## Rollout

1. **Key, judge and keep rules, with [`doc/testing.md`].** Items 1 to 8 and 10 of the tests.
   `--check-types` stands on its own verdicts locally. CI is unchanged: the narrowing
   job names no cache and runs everything. The text that says a checked run "runs every
   test, whatever verdict stands" ([`doc/testing.md`], `build/test.tl:92`,
   `build/test_key.tl:2010`, `ci.yml:1873`, `ci/cosmic_ci/orchestration.tl:1684`) changes with it.
2. **CI.** Item 9 and the steps above. The first runs are cold. Check the run's census
   (`--census`) for the part that moved when a run stands on less than it should.
3. **Measure, then tighten.** Lower `checked_narrowing_timeout_ns` (1800 s) to a bound
   derived from the number of rows that moved, as the checked gather does
   (`gather_budget`). Decide the open questions below with a week of runs.

## What it saves

Estimates. The sample is the 60 commits at the tip of main (2026-10-30 to 2026-10-31).
A commit moves a test when a file it changes is in the import closure of the test's
module (`imports` and `decl_imports`, weighted by the 7749 `test_*` functions), and
moves every test when it changes C, `vendor/`, `patch/`, `build.zig` or
[`build/harness_epoch.tl`]. A change to a declared data file is left out, so the shares
are a little low. This is what a leg's ordinary suite reruns too, so it is what standing
saves there.

| | Share of tests that run |
| --- | --- |
| median commit | 23% |
| mean | 45% |
| lowest quarter | under 7% |
| commits that run all | 21 of 60 (9 of them move the epoch file) |

On the suite's 726 to 861 s, the mean runs 330 to 390 s of it and the median 170 to 200 s,
so the job saves about 400 to 470 s of a runner on average and 560 to 660 s on the median
commit. The other 160 to 205 s (boot and finish, **measured**), the compile of the tree with
checks (1 to 66 s, **measured**) and the keying (8.5 s, **measured**) stay: a median run takes
6 to 8 minutes in place of 15 to 18, a mean run 8 to 11, and the 35% of commits that run
all take what they take now. The 140 skips (**measured**; 53 of them for Seatbelt, which holds a child on macOS alone) run every time, a few seconds in all (estimated).

It does not shorten the queue's critical path: the job already ends with the shortest leg
([`ci/README.md`], "the checked jobs"). It returns a runner for 7 to 11 minutes of a typical
full run, and a queue run stacked on another starts from the other's rows.

## Open questions

- **Share the epoch?** A checked-only epoch, `checks_epoch`, held by checked keys alone,
  would let an edit to the hooks rerun the narrowing job and leave the ordinary suites
  standing. It costs a second rule in `harness_epoch_test` and is used 0 times in 60
  commits. This plan does not add it.
- **Foreign features.** The checked suite's gather looks a test up under the key of another
  host that differs only in processor features (`COSMIC_TEST_FOREIGN_FEATURES`). If the
  runner pool has several feature sets, the narrowing cache misses on each; the census
  of the first week says whether it does.
- **Stand with violations?** A test that meets a reported-only violation reruns every
  time. Keeping its rows in the verdict would let it stand, at the price of a second
  table in the shared cache. The measure above decides.
- **Equal bytes across modes.** The plan keeps each mode off the other's verdicts. Today an
  ordinary run stands on a checked pass when a closure compiles to the same bytes in both
  modes, which is sound only while nothing else differs; the fuzz budget shows a mode can
  matter without changing bytes. Allowing it again would save little: such closures are
  the few that hold no typed parameter and no narrowed read.
- **Shares.** Whether the job should split once it is mostly standing (the `TODO:` at
  `ci.yml:1880`). The likely answer is no.

[`.github/workflows/ci.yml`]: ../../.github/workflows/ci.yml
[`build.boundary_hook_test`]: ../../build/boundary_hook_test.tl
[`build.declared_key`]: ../../build/declared_key.tl
[`build.fact_hook_test`]: ../../build/fact_hook_test.tl
[`build.fuzz`]: ../../build/fuzz/init.tl
[`build.harness_epoch_test`]: ../../build/harness_epoch_test.tl
[`build.harness_epoch`]: ../../build/harness_epoch.tl
[`build.identity`]: ../../build/identity.tl
[`build.shared_verdicts`]: ../../build/shared_verdicts.tl
[`build.test_key`]: ../../build/test_key.tl
[`build.test_worker`]: ../../build/test_worker.tl
[`build.test`]: ../../build/test.tl
[`build.type_violations_test`]: ../../build/type_violations_test.tl
[`build.type_watch`]: ../../build/type_watch.tl
[`build/closure_store_test.tl`]: ../../build/closure_store_test.tl
[`build/fact_hook_tool_test.tl`]: ../../build/fact_hook_tool_test.tl
[`build/harness_epoch.tl`]: ../../build/harness_epoch.tl
[`build/runtime_checks_tool_test.tl`]: ../../build/runtime_checks_tool_test.tl
[`build/sandboxed_verdicts_test.tl`]: ../../build/sandboxed_verdicts_test.tl
[`build/shared_verdicts_test.tl`]: ../../build/shared_verdicts_test.tl
[`build/test_worker_test.tl`]: ../../build/test_worker_test.tl
[`ci/cosmic_ci/orchestration_test.tl`]: ../../ci/cosmic_ci/orchestration_test.tl
[`ci/README.md`]: ../../ci/README.md
[`cosmic/json_test.tl`]: ../../cosmic/json_test.tl
[`doc/testing.md`]: ../testing.md
[`importer.checked_tool`]: ../../build/importer.tl
[`lang.boundaries_fuzz_test`]: ../../lang/boundaries_fuzz_test.tl
[`lang.boundaries_test`]: ../../lang/boundaries_test.tl
[`lang.boundary_checks`]: ../../lang/boundary_checks.tl
[`lang.check`]: ../../lang/check.tl
[`lang.codegen`]: ../../lang/codegen.tl
[`lang.fact_wraps`]: ../../lang/fact_wraps.tl
[`shared_verdicts.location`]: ../../build/shared_verdicts.tl
[`shared_verdicts.named`]: ../../build/shared_verdicts.tl
[`test_key.keep`]: ../../build/test_key.tl
[`worker.fact`]: ../../build/test_worker.tl
[`worker.judge`]: ../../build/test_worker.tl
