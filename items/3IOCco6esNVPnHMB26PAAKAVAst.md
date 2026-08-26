## Goal

G5 — adversarial verification, through the container `test runner: tests
run because they are defined` (3IOCIBGe). This is that container's
**phase 2**: the runner module itself, standalone and callable by hand
before any toolchain change.
`docs/decisions/d29-tests-run-because-defined.md` is the contract it
lands against; nothing here re-decides anything that record settled.

## Evidence

Measured 2026-08-26 at main `b4ad036b`, from the repo root.

- **Both files are new.** `ls cosmic/test.tl cosmic/test_test.tl` →
  neither exists, so the whole 500-line cap is headroom for each.

- **The public surface is a committed floor.**
  `grep -c '\] = true' _build/public_surface_baseline.tl` → **49**, and
  `ls cosmic/*.tl cosmic/*/init.tl | grep -v '_test\|_example\|^cosmic/_' | wc -l`
  → **50** (the extra file is `cosmic/init.tl`, which yields the bare
  name `cosmic` that the visibility rule drops — `grep -n '"cosmic"'` on
  the baseline is empty). Adding `cosmic/test.tl` makes it 50 names.
  `_build/public_surface.tl:12` prints the regen command:
  `bin/cosmic --make run _build/public_surface.tl --baseline`.

- **The coverage floor fails on a file it has never seen.**
  `_tool/coverage/baseline.tl:8-11` — the gate fails "when the file set
  drifts (a new file missing from the baseline …)", and
  `bin/cosmic --make coverage --baseline` rewrites it.

- **A public module must be documented, and the index is derived.**
  `cosmic/surface_test.tl:105` (`test_public_modules_are_documented`)
  fails any public module with no entry in the embedded docs index. The
  entry is generated from the module's own `---` header, so writing that
  header is the whole requirement — there is no list to edit.

- **`cosmic/**` may not import the records grammar.** The strip floor is
  `cosmic/**` (AGENTS.md), and `_tool/records.tl` is internal;
  `grep -rn 'require("_tool' cosmic/` returns exactly one hit and it is a
  test file (`cosmic/coverage/init_test.tl:15`). So the runner reproduces
  the two spellings it needs and a test pins the agreement — the standing
  precedent being `cosmic/check.tl:16`'s own `EXIT_SKIP = 2`, mirrored
  from `_tool/records.tl:30` and asserted equal at
  `_tool/records_test.tl:130`. The spellings:
  - `_tool/records.tl:147` — `row("fail", name, 0, "")` renders
    `"✗ " .. name`.
  - `_tool/records.tl:164` — `counts(p, f, s)` renders
    `"<N> checks: <P> passed[, <F> failed][, <S> skipped]"`.
  - `_tool/records.tl:29-30` — `EXIT_OK = 0`, `EXIT_SKIP = 2`.
  - `wc -l _tool/records_test.tl` → **144** (356 lines of headroom).

- **A chunk's return value is discarded.** `cmd/cosmic/main.tl:476` runs
  the script chunk as `run_chunk(table.unpack(args))` inside an `xpcall`
  and throws the result away; the script path then returns 0 at `:481`.
  So D29's *illustrative* tail —
  `return require("cosmic.test").main({...})` — exits **0** on a failing
  test file whatever `main` returns. That is a fact about the tail, which
  belongs to 3IOCdHTM; it is recorded here because it is the reason
  `main` in this slice returns its code rather than exiting (below).

- **Capturing the runner's output in a test is a solved pattern.**
  `_tool/example.tl:156-182` swaps `io.write` (and `_G.print`) around the
  code under test and restores both.
  `debug.traceback(tostring(err), 2)` is used at `_cli/run.tl:48` and is
  the tree's only use of it.

- **`cosmic.env` covers the filter's environment half.** `env.get`,
  `env.set` and `env.unset` are all on the module record
  (`cosmic/env.tl:179-182`), so the test can drive `COSMIC_TEST_FILTER`
  without a `cosmo.*` call.

- **Three further gates bind a new public module, found at pull
  (2026-08-26, running `--make coverage --baseline` against the built
  tree) and not by this spec's first pass.** They are facts about the
  gate set, not decisions, so they are recorded here rather than
  bounced:
  - `cosmic/example_coverage_test.tl:103` — every public module needs a
    `*_example.tl` and the waiver allowlist is closed to new entries, so
    `cosmic/test_example.tl` is required, not optional.
  - `_build/env_vars_test.tl:78` — every `COSMIC_*` name a non-test
    source reads must be declared in `_cli/env_vars.tl`, so reading
    `COSMIC_TEST_FILTER` obliges a row there.
  - `_build/casts_test.tl:54` — the per-file cast baseline starts at 0
    for a new file, so the new files carry no `as` at all.

## Change

Two new files, one added test in an existing one, and the two committed
floors those regenerate. Nothing else in the tree moves.

### `cosmic/test.tl` — new, public

A `---` doc comment header whose first line is the module's one-line
description; that line is what `cosmic --docs` indexes and what
`cosmic/surface_test.tl` requires. The header also records, the way
`cosmic/check.tl:14` does for `EXIT_SKIP`, that the two output spellings
below are `_tool/records.tl`'s and are reproduced rather than imported
because `cosmic/**` may not require the internal tree.

The exported surface is two types and one function:

```teal
local record Case
  name: string
  fn: function()
end

local record Options
  --- A plain SUBSTRING matched against a case name — the benchmark and
  --- example runners' contract, not a Lua pattern. When absent,
  --- COSMIC_TEST_FILTER is read instead.
  filter: string
end

main: function(cases: {Case}, opts?: Options): integer
```

`main` does exactly this, in order:

1. Resolve the filter: `opts.filter` when it is a non-empty string, else
   `require("cosmic.env").get("COSMIC_TEST_FILTER")` when that is a
   non-empty string, else no filter.
2. Select cases **in the order given** — source order; never sorted,
   never shuffled. With a filter, keep the cases satisfying
   `name:find(filter, 1, true)`; the literal `1, true` is what the
   `find-needle` lint requires and the substring contract is what it
   means here.
3. If no case is selected, write the skip output below and return `2`.
4. Otherwise run each selected case under
   `xpcall(case.fn, handler)`, where `handler` is
   `function(e: any): string return debug.traceback(tostring(e), 2) end`.
   A throw records that string against the case's name and the loop
   **continues to the next case**. Nothing aborts the run.
5. Write the output below and return `0` when every selected case passed,
   `1` when any failed.

`main` writes with `io.write` to stdout and never calls `print`, so a
caller can capture all of its output by swapping `io.write` alone. It
never calls `os.exit` and never throws: it is an ordinary `cosmic.*`
library function that returns a value, which is what D23 requires of
every `cosmic.*` module but `cosmic.check`.

The output, exactly:

- One block per FAILING case, in run order, before the summary: the line
  `✗ <name>`, then the recorded traceback string with each of its lines
  indented four spaces.
- Then, always, the counts line followed by a newline:
  `<N> checks: <P> passed[, <F> failed]`, where `N` is the number of
  cases RUN. The skipped count is always 0 in this slice — there is no
  per-test skip (D29 keeps `check.needs`/`check.reap` exiting the
  process) — so the `, <S> skipped` arm never appears.
- When a filter selected nothing while `cases` is non-empty, one line
  before the counts line:
  `no tests matching '<filter>' (found <N> total)`. When `cases` itself
  is empty, nothing before it. Either way the counts line is
  `0 checks: 0 passed` and the return value is `2`.

### `cosmic/test_test.tl` — new

Legacy mode: every `test_*` self-called on the line after its `end`, as
the whole tree still is. Uses `cosmic.check`. A local helper wraps a
`main` call, swapping `io.write` for a collector and restoring it on both
the normal and the throwing path, and returns the exit code with the
captured text. The tests:

- `test_every_case_runs_past_a_failure` — three cases, the middle one
  throwing: the third case's side effect happened, the return is `1`, and
  the output names the middle case.
- `test_all_passing_returns_zero` — two passing cases: return `0`, last
  output line `2 checks: 2 passed`.
- `test_failure_output_names_the_function_and_carries_a_traceback` — one
  throwing case: the output contains `✗ <name>` and, indented below it,
  the thrown message and a `stack traceback:` whose frames name this
  file. (They name the COMPILED chunk, `o/cosmic/test_test.lua`, since a
  test runs as the chunk the build produced — measured at pull.)
- `test_source_order_is_run_order` — each case appends its name to a
  list; the list equals the input order.
- `test_empty_case_list_is_a_skip` — `main({})` returns `2` and writes
  `0 checks: 0 passed`.
- `test_filter_selects_by_substring` — three cases and
  `{filter = "beta"}`: only the matching case ran, return `0`, counts
  line `1 checks: 1 passed`.
- `test_filter_matching_nothing_is_a_skip` — return `2`, and the output
  names the filter and the total.
- `test_the_env_var_is_the_filter_when_no_option_is_passed` — `env.set`
  around the call and `env.unset` after, asserting the same narrowing;
  and that an empty-string value is treated as no filter at all.
- `test_a_failing_case_does_not_leak_io_write` — after a `main` call
  whose case throws, `io.write` is the real one again.

### `_tool/records_test.tl` — one added test

`test_the_public_runner_and_the_records_grammar_agree`: capture
`require("cosmic.test").main` over one passing and one failing case, and
assert the summary line is byte-identical to `records.counts(1, 1, 0)`
and the failure line to `records.row("fail", <name>, 0, "")`. This is the
drift guard the reproduced grammar needs, in the file that already guards
`check.EXIT_SKIP` against `records.EXIT_SKIP` at `:130`.

### `cosmic/test_example.tl` — new

The `*_example.tl` a public module owes (`cosmic/example_coverage_test.tl`,
whose waiver list is closed). Two `Example_*` functions, each with a
`-- Output:` block so the example runner compares real output:
`Example_main` runs two passing cases and prints the exit code;
`Example_filter` shows the substring narrowing and the
nothing-matched skip. Bodies are extracted and recompiled, so each
`require` lives inside its function.

### `_cli/env_vars.tl` — one added row

`COSMIC_TEST_FILTER`, `public = true`, described as the runner's name
filter. `_build/env_vars_test.tl` fails a `COSMIC_*` name that code reads
and the registry does not declare, and `--help` renders the public rows.

### The two committed floors

Regenerate and commit both, with the commands the gates print — in
scope, and the only sanctioned way to move either:

- `bin/cosmic --make run _build/public_surface.tl --baseline` →
  `_build/public_surface_baseline.tl` gains `["cosmic.test"] = true`.
- `bin/cosmic --make coverage --baseline` → `.cosmic-coverage` gains rows
  for the two new files.

## Non-goals

- **No toolchain change.** No discovery walk, no compile/check seam, no
  generated tail, no `_cli/lint.tl` edit, no `_tool/testrun.tl` edit, no
  `.tests` format change, no `--filter` flag. Those belong to 3IOCdHTM
  and 3IOCdZCA. `_tool/records.tl` itself is not touched — only its test
  file gains one function.
- **No test file in the tree migrates.** The 2,870 self-call lines stay
  (3IOCdooE). The tree remains entirely legacy mode, which is why this
  slice lands green with zero edits to existing tests.
- **`main` never exits and never throws.** D23 permits only
  `cosmic.check` (and D22's CSPRNG) to exit or throw from `cosmic.*`, and
  D29's own consequences say D23 stands unchanged. Turning this return
  value into the process's exit status is 3IOCdHTM's job and its tail
  must therefore be
  `os.exit(require("cosmic.test").main({...}))` — D29's illustrative
  `return require("cosmic.test").main({...})` exits 0 on failure, because
  `cmd/cosmic/main.tl:476` discards the chunk's return value. Do not
  "fix" that here by exiting from the module, and do not edit
  `cmd/cosmic/main.tl`.
- **No per-test skip, no subtests, no `t` handle, no per-test temp
  directory, no per-test wall time, no parallelism, no shuffle.** Each is
  rejected or deferred by D29.
- **No assertion vocabulary grows.** `assert` and `cosmic.check` remain
  the whole of it.
- **No docs prose.** `AGENTS.md`, `docs/guides/**` and `sys/help.md`
  describe the convention as it IS, and it does not change until the
  toolchain lands. The module's `---` header is the only documentation
  this slice writes, and no decision record is amended.
- **Frozen:** the 0/2/fail exit grammar; the `records` row and counts
  spellings (reproduce them exactly, never redefine them); and, once this
  ships, `main`'s signature, by D20's charter as D29 notes.

## Acceptance

Run from the repo root.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `o/bin/cosmic --make test cosmic/test_test.tl` passes.
3. `o/bin/cosmic --make test _tool/records_test.tl` passes.
4. `o/bin/cosmic --make test cosmic/surface_test.tl` passes — this is
   what proves `cosmic.test` loads and is documented.
5. `o/bin/cosmic --docs cosmic.test` prints the module reference, its
   first line being the header's one-line description.
6. `grep -c '\] = true' _build/public_surface_baseline.tl` prints `50`
   (it is `49` today).
7. `grep -c 'require("_' cosmic/test.tl` prints `0` — the module reaches
   no internal tree.
8. `grep -c 'os.exit' cosmic/test.tl` prints `0`, and
   `grep -cE '^ *error\(' cosmic/test.tl` prints `0`.
9. `wc -l cosmic/test.tl` and `wc -l cosmic/test_test.tl` are each
   `≤ 500` — the cap `--check lint` enforces.
10. `o/bin/cosmic --make example cosmic/test_example.tl` passes — the
    example a public module owes.
11. `git diff --name-only origin/main` prints exactly, in any order:

    ```text
    .cosmic-coverage
    _build/public_surface_baseline.tl
    _cli/env_vars.tl
    _tool/records_test.tl
    cosmic/test.tl
    cosmic/test_example.tl
    cosmic/test_test.tl
    ```

## Enablement

none needed. The two wrong turns this slice invites are both closed by an
Acceptance command rather than by prose: reaching into `_tool.records`
for the grammar is caught by step 7, and exiting the process from a
`cosmic.*` module — which D29's illustrative tail invites — is caught by
step 8, with the measured reason in Non-goals. Everything else the
implementer needs is read above at real line numbers: the two grammar
spellings, the `io.write` capture pattern, the traceback call, the
`cosmic.env` surface, and both floor-regen commands.

One general gap is real but is NOT a blocker for this slice: nothing in
`--check lint` refuses a `cosmic/**` file that requires `_cli`, `_make`,
`_tool`, `_build`, `_perf`, `_docs` or `_fuzz` — `_cli/visibility.tl`
only polices the opposite direction (an outside file reaching a
`cosmic.*` shard). The strip floor is AGENTS.md prose today. That lint is
filed as its own capture, `3ISJfg8N`; this slice is fenced by step 7 in
the meantime and does not wait for it.
