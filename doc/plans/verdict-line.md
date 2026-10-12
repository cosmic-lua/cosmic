# removing the verdict line

this document proposes ending the convention that every `cosmic` verb's
output ends in a verdict line (`fix: PASS (3 Teal files, 0 fixed, 12 ms)`),
and says where what the line carries goes instead. once its PRs merge the
file is deleted, as [roadmap.md](../roadmap.md) deletes what ships.

the scope is the verbs, `boot` and `stage`, and [`Logger.verdict`]. lines
of the same shape that scripts and test programs print as their own
reports (eval's `check: PASS`, the proofs', the pty fixtures', the C test
programs') are not verbs' and stay.

## why

- **the exit code already is the verdict.** the line's PASS or FAIL is the
  exit code written again: [`build/verbs_fixture.tl`] tests that the two
  agree.
- **it takes stdout from the verb's result.** a verb whose stdout is data
  ends that data with a line that is not data. `sql --to` writes its line
  on stderr for that reason. `uses`, `todos` and `docs` print results a
  pipe could read, and end them the same way.
- **it repeats complaints.** a refusal is complained about on stderr, then
  said again in the verdict. dispatch's fallback (`usage: see cosmic help`,
  `the tool is stale`) restates exit codes 2 and 3.
- **it carries machinery.** [`build/verdict.tl`] tracks whether a line was
  given. dispatch reads that flag to decide whether a refused command line
  may be a stale tool's ([staleness after a refusal](#staleness-after-a-refusal)).
  [`build/invoke.tl`] saves and restores it around in-process runs.
  [`build/verb_spec.tl`]'s `bare`, `exits` and `passthrough`, and
  [`build/verb_cases.tl`]'s classification, sort verbs by whether they
  give one.

## decisions

- **the exit code is the verdict**: 0 passed, 1 failed, 2 the command line
  was refused, 3 the tool is stale. `cosmic help exit` keeps the codes and
  drops the line. in [design.md](../design.md), principle 8's "gates end
  in a verdict line" becomes "a gate's verdict is its exit code", and the
  paragraph on verbs drops "ends in a verdict line".
- **stdout is the verb's result; stderr says how the run went.** a verb
  that gave a verdict ends a run it got past its command line with a
  summary line on stderr: `<verb>: ` and what the verdict's detail said,
  its counts and its elapsed time, without PASS or FAIL
  (`fix: 3 Teal files, 0 fixed, 12 ms`). so what only a verdict said
  keeps a place there:
  - `db`, `uses`, `todos` and `docs` finding nothing (exit 1 as now). for
    `docs`, that is the "nothing named or documented as …" text, which a
    one-word query says only in its verdict.
  - `fix`'s hints: "`cosmic fix` rewrites them in place", "`cosmic fix`
    links them", and the Markdown rewrite. its `fix: FAIL  …` and
    `fix: would fix  …` lines stay on stdout as its result.

  a refused command line gets no summary: its complaint says why. a
  summary that only repeats a complaint (`sql`'s, `bom`'s, `refresh`'s
  and `help`'s failures) is dropped.
- **a figure a consumer parses moves into the verb's result on stdout:**
  - `build` prints each executable it wrote, the bare path on a line, so
    a pipe can use it. this is the one fact consumers parse from its
    verdict. the ` (host)` mark stays in its summary.
  - `test` keeps its summary on stdout, since its counts are a test run's
    result, worded as an outcome: `test: 6151 tests passed in 596 modules;
    395 ran, 5699 stood, …` or `test: 2 of 6151 tests failed, 0
    infrastructure errors, …`. the sandbox and shard notes stay.
- **`boot` and `stage`** write their summary on stderr like a verb, without
  PASS: `boot: 3 targets, …`. `boot`'s failures, about 30 of which say why
  only in a verdict, and the two that write `boot: FAIL` with `say`,
  become complaints.
- **the shared logger stays.** [`build/verdict.tl`] is also the `"cosmic"`
  logger that 18 modules write through. it is renamed `build/logger.tl`
  and keeps only that.
- **[`Logger.verdict`] leaves [`cosmic.log`]**, removed outright, as
  [the stdlib plan](stdlib-simplification.md) removes things. nothing
  outside `build/` calls it except [`build/verify_codesign.tl`], which
  stops. [`cosmic.removed`]'s `members` cannot key a record's method, since
  no `require` binds the Logger type, so the method joins the list in
  that table's `TODO:` beside the Conn methods.

## staleness after a refusal

after a verb exits 2 without a verdict, dispatch asks
[`build/reboot.tl`]'s `stale_exit` whether the tool is stale, since a stale
tool refuses an option the tree added. a verb that gave its own verdict
skips that question. today the verbs that skip it this way are `sql`, which
must never open the work database, `help`, which calls `stale_exit`
itself, and `bom` and `refresh`, which are `fresh` and so were checked
before they ran.

the rule is stated directly first (step 3a): dispatch asks after an
exit 2 unless the verb is bare or `fresh`, or its spec says
`recheck_on_refusal = false`, as `help`, `todos` and `sql` do. `bare`
keeps one meaning: a verb whose output is data prints no summary. its
`exits` sentence and its `passthrough` reason stay. the `TODO:` above that check in
dispatch stays. it is about the stale tool's complaint, not the line.

## what reads the line now

each reader moves to the exit code, or to the result's new home, in the
PR that changes what it reads.

- **CI:**
  - [`ci/cosmic_ci/suite_output.tl`] parses `test: PASS (…)` and
    `test: FAIL (…)`. its `status` takes a failure from the exit code, and
    on exit 0 it takes "pass" from the summary or "unreported" without
    one. [`ci/cosmic_ci/orchestration.tl`]'s `native_ran_every` needs
    "pass" and reads `ran` and `stood`. the parser reads the reworded
    summary into the same `suite_runs` columns.
  - `fuzz.tl` collects `test: FAIL` lines, which matches the per-test
    lines that stay.
  - `product_setup.tl` and `ci/fixtures/identity_test.tl:53` read
    `build`'s paths.
  - `ci/fixtures/identity_test.tl:168` and
    `ci/fixtures/self_rebuild_test.tl:361` read the test summary.
  - these fixtures run only in CI's platform fixtures phase. a PR that
    changes what they read runs [`ci/run-local`].
- **eval:** [`Grader.built`] reads `build`'s paths. [`Grader.api_failures`]
  and [`eval/summarize.tl`]'s "first green" read `test: PASS`, and
  summarize counts `docs: FAIL` among docs misses. they move to
  `build`'s stdout, to the exit code, to the summary's "tests passed"
  where a transcript holds no exit code, and to `docs`' summary.
- **perf:** [`build/perf.tl`] matches `; N ran, M stood`, which stays.
- **the guides:**
  - seven doctests match `test: [A-Z]+`: web-forms.md and the web, web-api,
    web-deploy, web-live, web-security and web-sessions guides.
  - project.md's `verdict` helper matches any verb's line and parses
    `build`'s path from one.
  - command-line.md parses `build`'s path and `help: PASS (1 verb`, and
    its prose and quickstart.md's say which verbs print no verdict.
- **the tests:** about 30 files assert on verdict lines. the largest are:
  - [`eval/check/grade_test.tl`]
  - [`ci/cosmic_ci/suite_output_test.tl`]
  - [`build/sql_test.tl`]
  - [`eval/summarize_test.tl`]
  - [`ci/cosmic_ci/fuzz_test.tl`]
  - [`ci/cosmic_ci/orchestration_test.tl`]
  - [`build/sandboxed_verdicts_test.tl`]
  - [`build/boot_test.tl`]

  [`build/verbs_tool_test.tl`]'s `test_every_started_verb_ends_in_a_verdict`
  becomes "every started verb says how it went": a run past its command
  line ends in a summary on stderr, and a refused command line exits 2
  with a complaint and stdout empty.

## the PRs

1. **give `build`'s paths a home.** `build` prints each path on stdout,
   still giving its verdict. eval's grader, CI's product setup and
   identity fixture, command-line.md and project.md read the new lines.
2. **reword the test summary.** [`test_report.passed`] and `failed` write
   the outcome sentence, which stands as `test`'s verdict line until
   step 3 ([`build/verdict.tl`]'s `summary` marks it given, and
   [`build/verbs_fixture.tl`] reads it as one). the harness epoch moves,
   since many tests judge a run by its summary. the following move with
   it:
   - CI's `SuiteOutput` and the two fixtures that read the summary;
   - eval's readers, which keep the old line for an arena's older tool;
   - the seven guide doctests and project.md's helper, which match
     `test: PASS`;
   - the tests on the summary.
3. **remove the line from the verbs**, in two PRs.
   - 3a: add `recheck_on_refusal`, so the stale check after a refusal no
     longer reads `given`.
   - 3b:
     - drop every `:verdict` call in `build/` and dispatch's fallback;
     - rename [`build/verdict.tl`] and drop `given`, `on_stderr` and
       `summary`;
     - move each verdict's detail to the stderr summary, and make `boot`'s
       failures complaints;
     - rewrite `cosmic help exit`, the per-verb help note, [`cosmic.cli`]'s
       help prose, design.md, command-line.md, quickstart.md and the guides'
       remaining output blocks;
     - replace the ends-in-a-verdict test;
     - move eval's `docs: FAIL` count to `docs`' summary.
4. **remove [`Logger.verdict`]** from [`cosmic.log`]:
   - its example, its tests, and [`build/verify_codesign.tl`]'s call;
   - `verdict` in [`build/contracts.tl`]'s quieted methods;
   - the method's line in [`cosmic.removed`]'s `TODO:`.

## what is lost

- **a word to read at a glance.** someone reading the output, a person or
  an agent, sees `PASS` or `FAIL` without asking for the exit status. the
  test summary keeps that ("passed", "failed"). the other verbs'
  summaries say what they found or did.
- **one shape across verbs.** the summaries keep `<verb>: `, but no single
  pattern finds a verb's outcome in its output. the readers above are the
  only ones that use one.

[`build/boot_test.tl`]: ../../build/boot_test.tl
[`build/contracts.tl`]: ../../build/contracts.tl
[`build/invoke.tl`]: ../../build/invoke.tl
[`build/perf.tl`]: ../../build/perf.tl
[`build/reboot.tl`]: ../../build/reboot.tl
[`build/sandboxed_verdicts_test.tl`]: ../../build/sandboxed_verdicts_test.tl
[`build/sql_test.tl`]: ../../build/sql_test.tl
[`build/verb_cases.tl`]: ../../build/verb_cases.tl
[`build/verb_spec.tl`]: ../../build/verb_spec.tl
[`build/verbs_fixture.tl`]: ../../build/verbs_fixture.tl
[`build/verbs_tool_test.tl`]: ../../build/verbs_tool_test.tl
`build/verdict.tl`: ../../build/verdict.tl
[`build/verify_codesign.tl`]: ../../build/verify_codesign.tl
[`ci/cosmic_ci/fuzz_test.tl`]: ../../ci/cosmic_ci/fuzz_test.tl
[`ci/cosmic_ci/orchestration.tl`]: ../../ci/cosmic_ci/orchestration.tl
[`ci/cosmic_ci/orchestration_test.tl`]: ../../ci/cosmic_ci/orchestration_test.tl
[`ci/cosmic_ci/suite_output.tl`]: ../../ci/cosmic_ci/suite_output.tl
[`ci/cosmic_ci/suite_output_test.tl`]: ../../ci/cosmic_ci/suite_output_test.tl
[`ci/run-local`]: ../../ci/run-local
[`cosmic.cli`]: ../../cosmic/cli.tl
[`cosmic.log`]: ../../cosmic/log.tl
[`cosmic.removed`]: ../../cosmic/removed.tl
[`eval/check/grade_test.tl`]: ../../eval/check/grade_test.tl
[`eval/summarize.tl`]: ../../eval/summarize.tl
[`eval/summarize_test.tl`]: ../../eval/summarize_test.tl
[`Grader.api_failures`]: ../../eval/check/grade.tl
[`Grader.built`]: ../../eval/check/grade.tl
[`Logger.verdict`]: ../../cosmic/log.tl
[`test_report.passed`]: ../../build/test_report.tl

[`build/verdict.tl`]: ../../build/verdict.tl
