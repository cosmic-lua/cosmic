## Goal

3IOCIBGe (D29: a test runs because it is defined) — the payoffs the
record names, per-test identity and a substring filter, delivered
through the runner and report so the 3IU6* migration lights them up.

## Change

Three coordinated edits, measured 2026-08-27 on main `bbeaea6e`:

1. **`cosmic/test.tl` (172 lines, 328 headroom)** — `main` prints
   `✓ <name>` after each passing case, beside the `✗ <name>` row it
   already prints on failure (`cosmic/test.tl:152`). These per-case
   rows ARE the child's per-test output the parent parses; a graph run
   captures stdout to `.out`, so nothing new reaches a terminal unless
   the file fails. Extend `cosmic/test_test.tl` (190 lines): its
   output assertions gain the `✓` rows, and the pass/fail/filter cases
   assert the exact row set in order.

2. **`_tool/testrun.tl` (337 lines, 163 headroom)** —
   - `run`: after capture, scan the child's stdout for lines matching
     exactly `✓ test_*` / `✗ test_*`. One or more matches is runner
     mode: write `.tests` as one `<name> pass` / `<name> fail` line
     per row, in output order — the statuses ARE what ran, so a
     filtered child records only the selected cases. No matches keeps
     today's names-only scrape verbatim (`_tool/testrun.tl:159-177`),
     so legacy files' sidecars stay byte-identical.
   - `run` gains an `Options` record with a `filter` field (new third
     parameter, optional); when set, append
     `COSMIC_TEST_FILTER=<value>` to `child_env` after the inherit
     loop (`_tool/testrun.tl:59-69`), so it overrides an inherited
     value. The child side already honours the variable
     (`cosmic/test.tl:23,47-62`), and the e2e harness in
     `_tool/seam_test.tl:100-103` already drives it.
   - `report`: a file whose `.tests` sidecar carries statuses
     contributes its per-test counts to the summary counts line
     (each `pass` line one passed, each `fail` line one failed), and
     its entry in the `Failures:` section leads with its failed test
     names. Every other file — fmt/lint/example sidecars with no
     `.tests`, legacy test files with names-only sidecars —
     contributes exactly one check with its file status, today's
     behavior unchanged. The gate invariant holds by construction: a
     failing test or failing file yields `failed > 0` in the counts
     line that `records.parse_counts` reads
     (`_cli/build/steps.tl:185`).

3. **`cmd/cosmic/main.tl` (499 lines — 1 line of headroom, so the
   change must free room)** — register `filter` as a value-taking long
   option (`long_needs_arg` in `_cli/args.tl`), read
   `p.values["filter"]` into opts, and thread it into `testrun.run`'s
   new options at the `--test` dispatch (`cmd/cosmic/main.tl:398-401`).
   Note the payload slice: everything after `--test`'s own argument is
   the CHILD's argv (`cmd/cosmic/main.tl:126-150`), so `--filter`
   parses only BEFORE `--test`, as `cosmic --filter x --test OUT …` —
   state this in the option's help line. Make room by moving the
   `--test` and `--report` dispatch bodies (`cmd/cosmic/main.tl:
   396-410`) into `_cli/main_handlers.tl` beside `handle_compile` and
   `handle_check_types`, which is where the other dispatch bodies
   already live.

The sketch this item carried pointed at
`docs/design/test-runner.md` on branch `claude/cosmic-test-runner-rgb819`;
that ref no longer exists (`git ls-remote` finds no such branch) and no
such doc is in the tree — D29
(`docs/decisions/d29-tests-run-because-defined.md`) and the landed seam
(3IOCdHTM, `_tool/seam.tl`) are the context that replaced it.

## Non-goals

No `--make test --filter` surface: the graph caches a target's `.got`
by freshness, so a filtered result recorded there would stand as the
file's result until its inputs change — a graph-level filter needs its
own item with a cache answer. (COSMIC_TEST_FILTER leaking through the
environment into a graph run predates this item and is not widened or
fixed here.) No change to `_tool/records.tl`'s grammar — rows, counts
line format, and the counts/parse_counts round trip stay as asserted
by `_tool/records_test.tl`. No change to the 0/1/2 exit grammar. No
tree test file migrates to runner mode (that is 3IU6AZEx and
siblings). No discover changes.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/testrun_test.tl cosmic/test_test.tl
  _tool/seam_test.tl` passes, with new tests proving: a runner-mode
  fixture's `.tests` carries `<name> pass`/`<name> fail` lines in
  output order; a legacy fixture's sidecar is names-only,
  byte-identical to today's; `run` with a filter option delivers
  COSMIC_TEST_FILTER to the child and the sidecar records only the
  selected cases; `report` over a statused sidecar totals per-test
  and names each failing test, and over sidecar-less files keeps
  today's per-file counts.
- `wc -l < cmd/cosmic/main.tl` ≤ 500 (measured 499 today).

## Enablement

none needed — the seam (3IOCdHTM) landed and `_tool/seam_test.tl`
already drives runner-mode fixtures end to end under the bootstrap;
fixtures carry the proof, so nothing must land first.
