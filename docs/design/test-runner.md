# Design — the test runner

`--make test` grows a real runner: a `test_*` function runs because it
is **defined**, not because its file remembered to call it. The author
surface shrinks to the function itself; discovery, invocation,
per-test reporting, and filtering move into the toolchain, the way
`go test` owns them for Go.

This chart describes what exists, what changes, and the order the
changes land in. The tradeoffs worth a permanent record are marked for
a decision record (the `decide` skill) as the first landing step.

## What a test is today

A `*_test.tl` file is a **script**. It defines zero-argument
`local function test_*()` functions that throw to fail (`assert`,
`cosmic.check`), and calls each one on the line after its `end`:

```teal
local str = require("cosmic.string")

local function test_trim()
  assert(str.trim("  x  ") == "x")
end
test_trim()
```

`--make test` compiles the file and runs it as one child process per
file (`_tool/testrun.tl`), grading by the exit grammar: 0 pass, 2
skip, anything else fail. Three mechanisms hold the convention up:

- the `call-after-define` lint (`_cli/lint.tl`) fails any `test_*`
  not called immediately after its definition;
- warnings-are-errors: an uncalled `local function` is an unused
  local, so `--check types` refuses it — a forgotten call cannot
  slip through, but it surfaces as a confusing "unused variable"
  rather than as the actual mistake;
- `testrun` already scans the source for `^local function (test_%w+)`
  and records the names in a `.tests` sidecar, so the report can say
  how many functions a passing file contained.

### What the convention gets right (all kept)

- **A test file is a process.** Isolation for free, sandbox grants
  derived from the file's imports, `TEST_TMPDIR` per file, the
  0/2/fail grammar, coverage instrumentation at the process boundary.
- **A test is a plain function that throws.** No DSL, no test-handle
  argument, no registration API. Lua has `error`/`pcall`, so throwing
  *is* the failure mechanism — the reason Go needs `t.Fatal` does not
  exist here.
- **Strict typing of test bodies.** Unlike `Example_*`/`Benchmark_*`
  bodies (extracted textually and recompiled lax), a test file is
  checked whole, strictly, with its helpers and requires in scope.
- **Deterministic source order.** Tests run top to bottom.

### What it costs (all fixed)

- **The first failure kills the file.** One run reports one defect;
  whether the file's other 14 tests also broke is invisible until the
  next round trip. Go runs every test and reports each.
- **No per-test identity.** The report counts files; a test has no
  status, no wall time, no way to be named from the command line.
  Narrowing is by file path only — there is no equivalent of
  `go test -run`.
- **2,786 call lines of ceremony** across 260 files, each a chance to
  mis-pair a call with its function, held in place by a lint rule and
  a warning that exist only to police the boilerplate.

## The shape

Five pieces, smallest author surface first:

1. **The author writes only the function.**

   ```text
   local str = require("cosmic.string")

   local function test_trim()
     assert(str.trim("  x  ") == "x")
   end
   ```

   Defining a `test_*` function *is* enrolling it. No call, no
   registration, no required import. Helpers (functions without the
   `test_` prefix) and top-level fixture code are untouched — the
   chunk's top level still executes before any test runs.

2. **Discovery is a compile-time token walk.** The lexer walk that
   `call-after-define` uses today (top-level `local function test_*`,
   token-exact, so fixtures quoting `end` in strings never confuse it)
   becomes a shared module and the single source of the case list.
   Source order is preserved.

3. **The toolchain appends a generated tail to the compiled chunk.**
   For a runner-mode test file, the compile step compiles the source
   plus one appended statement:

   ```text
   return require("cosmic.test").main({
       {name = "test_trim", fn = test_trim},
       ...
     })
   ```

   In-chunk is the only place file-local functions are reachable, and
   appending changes no line number, so a failing test's traceback
   still points at the real source line. The same augmented source
   goes to the type checker — the checker checks what runs, and the
   uncalled-local warning never fires because the tail calls every
   test. The tree, the formatter, and `fmt` never see the tail: it
   exists only on the way into the compiler, mirroring how Go
   generates `_testmain.go` without it ever appearing in the package.

4. **`cosmic.test` is the in-process runner.** A small public module
   (`cosmic/test.tl`): `main(cases)` runs each case in order under
   `pcall`, records name + error + traceback on failure and **keeps
   going**, prints per-test failures and a counts summary in the
   records grammar (`_tool/records.tl`), and exits by the existing
   grammar — 0 all passed, 2 nothing ran (a test file with no tests
   is a skip, as an example file with no examples already is),
   nonzero otherwise. Public because a user project's compiled tests
   require it at runtime and because the test contract is product
   surface, not repo tooling.

5. **`testrun` and `--report` learn per-test results.** The `.tests`
   sidecar (names only, today) becomes one `name<TAB>status` line per
   test, written by parsing the child's structured output. The report
   then totals *tests* — `2786 tests: 2780 passed, 4 failed, 2
   skipped` — names each failing test directly, and can carry
   per-test wall time later without changing the format again.

### Decision table

| question | answer | why |
|---|---|---|
| registration API (`test.case(fn)`)? | no | moves the forgettable call, doesn't remove it; Go proved discovery-by-name |
| body extraction like `Example_*`? | no | recompiles bodies lax and orphans shared helpers; tests must stay whole-file, strictly typed |
| tests as globals in a custom `_ENV`? | no | trades a visible tail for invisible environment magic and cross-file global declarations |
| a `t` handle (`t.Error`, `t.Fatal`)? | no | throwing is the failure mechanism; `t.Error`'s continue-on-error can come later as a helper if ever needed |
| subtests? | no, not now | nothing in 2,786 tests needs them; the case-table shape leaves room |
| keep the exit grammar? | yes, unchanged | every runner, `record`, and the report grade by 0/2/fail; `check.needs`/`check.reap` keep exiting the process |
| where the runner lives | `cosmic/test.tl` (public) | user projects' tests require it; position is the manifest |
| where discovery lives | shared lexer walk in `_cli` | it needs `tl.lex`; the dispatcher is where the lexer-backed checks already live |
| run order | source order, no shuffle | deterministic like today; Go's shuffle is opt-in and unproven here |
| per-test temp dirs | no, `TEST_TMPDIR` stays per-file | smallest change that ships; a per-test dir is additive later |

## Mode dispatch and migration

A convention change across 260 files (and every user project) cannot
be a single cliff. The discovery walk classifies each test file:

- **runner mode**: no `test_*` is called at top level → compile with
  the generated tail.
- **legacy mode**: every `test_*` is called immediately after its
  definition → compile unchanged, run as a script, exactly today.
- **mixed** (some called, some not): a lint failure either way — the
  `call-after-define` rule generalizes to *all-or-nothing*: either
  every test self-calls (legacy) or none does (runner). A half-migrated
  file is the one shape that must never pass, because its uncalled
  half would silently not run under legacy semantics.

This makes migration incremental and safe per file, in this repo and
in user projects. The repo migrates mechanically — the same lexer walk
that finds a definition's `end` finds the call line after it, so a
one-shot script deletes the 2,786 call lines — and the legacy arm is
deleted once the tree and a release cycle are clean.

**The stale-toolchain hazard is already fenced.** A runner-mode file
under an old cosmic would define functions, call none, and exit 0 —
silent green, the worst outcome. It cannot happen: old cosmic's
strict compile rejects the file first (uncalled locals are unused-
variable warnings, and warnings are errors), and its lint names every
uncalled `test_*`. An old toolchain refuses new-style tests loudly
rather than passing them emptily. Inside this repo the question
doesn't arise at all: gate verbs converge, so tests always run under
the binary built from the tree.

**`.lua` test files stay legacy.** The `%.lua.test.got` rule exists so
a Lua-only project's tests are not silently skipped; those files are
copied, not compiled, so there is no seam to inject a tail. A `.lua`
test remains a self-calling script, and the docs say so.

## Semantics, precisely

- **Failure**: a test that throws is recorded (name, error, traceback)
  and the runner continues. The file's exit code is nonzero if any
  test failed. Output on failure names the function first — the
  property the self-call convention existed to provide.
- **Skip**: `check.needs` and `check.reap` keep their contract — they
  exit the *process* with code 2, because a missing fixture
  invalidates the file, not one test. A per-test skip (`test.skip`,
  a sentinel the runner catches) is a possible later addition; nothing
  in the migration needs it.
- **`os.exit` / crash mid-run**: the process dies with that code and
  `testrun` grades it as today; per-test results already printed are
  in `.out`. No new hazard — this is current behavior.
- **Filter**: `--make test <path> --filter <substring>` narrows by
  test name within the file, the same plain-substring contract the
  benchmark and example runners already honor. `testrun` passes it to
  the child as `COSMIC_TEST_FILTER`; `main` runs only matching cases
  and exits 2 when the filter matches none (mirroring the example
  runner's "filter matched nothing" skip).
- **Output**: quiet on pass, like today. Failures and the counts line
  use the records grammar so asserting tests and the report read one
  format.
- **Coverage, sandbox, deps**: unchanged. The process boundary,
  grants, and `.got`/`.out`/`.err`/`.time` sidecars are untouched;
  only `.tests` gains statuses.

## What changes, by file

| where | change |
|---|---|
| `cosmic/test.tl` (new) | the runner: `main(cases)`, ordering, pcall, per-test output, exit grammar, filter |
| `cosmic/test_test.tl` (new) | runner behavior pinned: continue-past-failure, skip file, filter-none skip, empty file skip, traceback names the test |
| `_cli/` discovery module (new, extracted from `lint.tl`) | one lexer walk classifying files (runner / legacy / mixed) and yielding the ordered case list |
| `_cli/build` compile seam | runner-mode `_test.tl` sources compile and type-check with the generated tail appended |
| `_cli/lint.tl` | `call-after-define` generalizes to all-or-nothing mode dispatch; deleted with the legacy arm at the end |
| `_tool/testrun.tl` | `.tests` gains per-test statuses parsed from child output; `--filter` passthrough |
| `_tool/records.tl` | a per-test row shape, if the existing row/counts grammar needs any addition at all |
| repo-wide `*_test.tl` | mechanical deletion of the 2,786 self-call lines |
| `AGENTS.md`, `docs/guides/` (lint, testing), `sys/help.md` | the convention as it now is; `--filter` documented |
| `docs/decisions/` | the record settling discovery-by-name, the generated tail, all-or-nothing dispatch, and the unchanged exit grammar |

## Phasing

1. **Decide.** Write the decision record; it is the contract the rest
   lands against.
2. **Runner.** `cosmic/test.tl` + its tests. Standalone: callable by
   hand before any toolchain change.
3. **Toolchain.** Discovery module, compile/check tail injection with
   mode dispatch, lint generalization, `testrun` + report upgrades.
   The tree is all-legacy, so this lands green with zero test edits.
4. **Migrate.** The mechanical call-line deletion, in batches by
   directory so each lands reviewable and green. The tree ends
   all-runner.
5. **Retire.** Delete the legacy arm and the lint rule after a
   release carries phase 3, so user projects had a version that
   understands both modes. A release note marks the break.
6. **Later, on evidence**: per-test wall time in the report, per-test
   temp dirs, `test.skip`, subtests.

## Non-goals

- No assertion-library growth: `assert` and `cosmic.check` remain the
  whole vocabulary.
- No parallelism within a file: the process-per-file model is the
  parallelism, and make already schedules it.
- No change to examples or benchmarks: their extract-and-recompile
  runners fit their contracts (lax bodies, output comparison, timing)
  and stay as they are.
- No mocking, fixtures, or lifecycle hooks: top-level chunk code
  before the tail is the setup mechanism, as it always was.
