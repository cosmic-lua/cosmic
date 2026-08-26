## Goal

G5 — adversarial verification. The parent container's phase 1: the
contract every other slice under it lands against. A test runs because
it is DEFINED, and this record settles what that costs before any of
the runner, the toolchain seam, or the 2,870-line migration is written.

## Evidence

Measured 2026-08-26 at main `7e8e1170`, from the repo root.

- **The source the container cites has moved.** The container and this
  item both point at `docs/design/test-runner.md` on branch
  `claude/cosmic-test-runner-rgb819`. That branch is **deleted**
  (`git ls-remote --heads origin | grep rgb819` is empty) and the file
  exists in no reachable ref. The durable source is the design-only PR
  itself, **whilp/cosmic#1366**, whose single added file is that
  document, 253 lines, still readable from the closed PR. Read it there;
  this spec quotes the parts the record needs, so the record can be
  written without it if the PR is ever unreachable too.

- **The next free number is D29.** `ls docs/decisions/` ends at
  `d28-shape-combinators.md`, and `tail -1 docs/decisions/README.md` is
  the `| D28 |` row. Numbers are never reused and never renumbered.

- **The form is D26's and the index is derived.** `_docs/derive.tl`
  parses the `# D<n> — <title>` first line into the table in
  `docs/decisions/README.md`, and `_build/docs_test.tl` fails the build
  when the committed table drifts from the records. A record whose H1 is
  malformed is a record the index cannot carry.
  `docs/decisions/d28-shape-combinators.md` is the shape to match: 113
  lines, five top-level bullets at `:3` `date`, `:4` `status`, `:25`
  `decision`, `:51` `rejected`, `:97` `consequences`, with `context`
  running from `:5`.

- **The counts in the design doc have drifted; these are today's.**

  ```text
  git ls-files '*_test.tl' | wc -l                                      # 266
  git ls-files '*_test.tl' | xargs grep -hcE '^local function test_' | paste -sd+ | bc   # 2870
  git ls-files '*_test.tl' | xargs grep -hcE '^test_[A-Za-z0-9_]*\(\)$' | paste -sd+ | bc # 2870
  ```

  The doc says "2,786 call lines across 260 files"; it is **2,870 across
  266** today, and definitions and call lines are equal — the tree is
  entirely legacy-mode, which is what makes the all-or-nothing rule land
  green with zero test edits. Use today's numbers in the record.

- **No existing record covers this, and one is adjacent.**
  `grep -il 'test runner\|test_\*' docs/decisions/*.md` returns exactly
  one file, `d23-check-throws.md`, and what it settles is that
  `cosmic.check` THROWS — its `:18` reads "a test's caller is the test
  runner", which assumes a runner without saying how a test reaches one.
  D23 stands unchanged under D29 and the record should say so in
  `consequences`: throwing stays the failure mechanism, and the runner's
  `pcall` is what turns it into a per-test result rather than a dead
  file. This is a new number, not an amendment.

- **The three mechanisms the record replaces are all in the tree
  today.** The `call-after-define` lint in `_cli/lint.tl`;
  warnings-as-errors, under which an uncalled `local function` is an
  unused local and `--check types` refuses it; and `_tool/testrun.tl`'s
  `^local function (test_%w+)` scan that already writes a `.tests`
  sidecar of names. The record's context has to name all three, because
  together they are the thing being given up.

## Change

One new file plus the derived index. No code.

1. **Write `docs/decisions/d29-tests-run-because-defined.md`**, first
   line exactly:

   ```text
   # D29 — a test runs because it is defined, not because its file called it
   ```

   Em dash, lowercase after it, one claim. The four sections in D26's
   order and spelling (`- **date:** 2026-08`, `- **status:** active`,
   then `context`, `decision`, `rejected`, `consequences`), matching
   `d28-shape-combinators.md`'s voice: lowercase, terse, real paths and
   real numbers.

   - **context** — the three mechanisms above, with the measured counts
     (266 files, 2,870 definitions, 2,870 call lines, equal today), and
     the three costs the convention carries: the first failure kills the
     file, so one run reports one defect; a test has no per-test
     identity, so narrowing is by file path only and there is no
     `go test -run` equivalent; and the ceremony is held up by a lint
     rule and a warning that exist only to police it, where the
     forgotten call surfaces as "unused variable" rather than as the
     actual mistake.

   - **decision** — one call with sub-bullets, exactly these four and no
     more:
     - **discovery is by name**, from the compile-time lexer walk
       `call-after-define` already uses: a top-level
       `local function test_*` IS the enrolment, token-exact so a
       fixture quoting `end` in a string cannot confuse it, and source
       order is the run order.
     - **invocation is a toolchain-generated in-chunk tail**, appended
       at the compile/check seam, never written to the tree and never
       seen by the formatter or `fmt` —
       `return require("cosmic.test").main({...})`. In-chunk because
       that is the only place file-local functions are reachable;
       appended because it changes no line number, so a failing test's
       traceback still points at the real source line; and the same
       augmented source goes to the type checker, so the checker checks
       what runs and the uncalled-local warning never fires.
     - **a file is all-or-nothing**: every `test_*` self-called is
       legacy mode and compiles unchanged; none self-called is runner
       mode and gets the tail; MIXED is a lint failure. The mixed case
       is the one shape that must never pass, because its uncalled half
       would silently not run under legacy semantics.
     - **the 0/2/fail exit grammar is unchanged** — 0 all passed, 2
       nothing ran, nonzero otherwise — and `check.needs`/`check.reap`
       keep exiting the process, because a missing fixture invalidates
       the file rather than one test.

   - **rejected** — the section D26 says to write hardest. Five, each
     with the reason it lost, drawn from #1366's decision table:
     - a **registration API** (`test.case(fn)`) — moves the forgettable
       call, does not remove it.
     - **body extraction** the way `Example_*` works — recompiles bodies
       lax and orphans shared helpers; a test file must stay whole-file
       and strictly typed, which is what it has today and what the
       example runner gives up.
     - **tests as globals in a custom `_ENV`** — trades a visible
       generated tail for invisible environment magic and cross-file
       global declarations.
     - **a `t` handle** (`t.Error`, `t.Fatal`) — throwing already IS the
       failure mechanism in Lua, so the reason Go needs one does not
       exist here.
     - **a per-file cliff instead of mode dispatch** — 266 files here
       and every user project's tests cannot migrate in one commit, and
       a half-migrated file must fail rather than half-run.

   - **consequences** — the honest costs alongside the wins. It enables
     continue-past-failure, per-test identity in the `.tests` sidecar,
     and a `--filter` matching the benchmark/example contract. It costs
     a compile seam that injects source the tree never contains, which
     is a new place a bug can hide, and it makes `cosmic/test.tl`
     PUBLIC API (a user project's compiled tests require it at runtime),
     so its signature is frozen by D20's charter once shipped. It
     forbids a half-migrated test file, permanently. And it leaves the
     legacy arm in place until a release has carried the toolchain that
     understands both modes, because a runner-mode file under an old
     cosmic must fail loudly — which it does: the old strict compile
     rejects the uncalled locals before the lint even speaks.
     Revisit if per-test isolation (a temp dir, a process) turns out to
     be needed, since the in-process runner is what forecloses it.

2. **Regenerate the index**: `bin/cosmic _docs/derive.tl`, which rewrites
   the table in `docs/decisions/README.md`. Commit the result. Do not
   hand-edit that table.

## Non-goals

- **No code.** `cosmic/test.tl` is not written, `_cli/lint.tl` is not
  changed, `_tool/testrun.tl` is not changed, and no `*_test.tl` loses a
  self-call line. Those are the container's later phases and each is its
  own slice; this record is what they land against.
- **`docs/design/test-runner.md` is NOT committed.** The record distills
  it; copying a 253-line design chart into the tree beside a record that
  settles the same questions is the duplication D12 separates. PR #1366
  stays the argument's archive.
- **No other record is touched.** No renumbering, no retitling, no
  status change on D1–D28, and no amendment to any of them. If the draft
  turns out to contradict a standing record, stop and say so rather than
  editing that record here.
- **The number is D29 and the H1 is the exact line above.** Do not
  reuse a number, do not renumber, do not reword the H1 to something
  shorter — `_build/docs_test.tl` gates the derived table against it.
- **One decision.** If the draft grows a second claim with its own
  losing option — a per-test skip sentinel, subtests, per-test temp
  dirs, a shuffle — cut it out; #1366 records those as "later, on
  evidence" and they are not settled here.
- **The exit grammar does not move.** Every runner, `_tool/records.tl`,
  and the report grade by 0/2/fail; the record states it unchanged and
  nothing in this slice may propose otherwise.

## Acceptance

Run from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic _docs/derive.tl` then
  `bin/cosmic --make test _build/docs_test.tl` passes — the derived
  index matches the records.
- `head -1 docs/decisions/d29-tests-run-because-defined.md` prints
  exactly
  `# D29 — a test runs because it is defined, not because its file called it`.
- `grep -c '^| D29 |' docs/decisions/README.md` prints `1` (today `0`).
- `grep -cE '^- \*\*(date|status|context|decision|rejected|consequences):\*\*' docs/decisions/d29-tests-run-because-defined.md`
  prints `6` — the four sections plus `date` and `status`, each once.
- `grep -c '^  - ' docs/decisions/d29-tests-run-because-defined.md`
  prints a number ≥ `9` — the four decision sub-bullets and the five
  rejected alternatives each get their own.
- `wc -l < docs/decisions/d29-tests-run-because-defined.md` prints a
  number ≤ `140` (D28, the longest recent record, is `113`).
- `git diff --name-only origin/main` prints exactly these two, and
  nothing else:

  ```text
  docs/decisions/README.md
  docs/decisions/d29-tests-run-because-defined.md
  ```

- `git ls-files '*_test.tl' | xargs grep -hcE '^test_[A-Za-z0-9_]*\(\)$' | paste -sd+ | bc`
  still prints `2870` — unchanged, because this slice migrates nothing.

## Enablement

none needed. The mechanism is in the tree and gated today: `_docs/derive.tl`
regenerates the index, `_build/docs_test.tl` fails the build on drift, and
the `decide` skill (`skills/decide/SKILL.md`) carries the form, the
"when a tradeoff earns a record" test and the amend-versus-supersede
rule. The one hazard this refinement removed was a dead citation — the
branch the argument lived on is deleted, and the durable source is
PR #1366, named in Evidence with the parts the record needs quoted
beside it.
