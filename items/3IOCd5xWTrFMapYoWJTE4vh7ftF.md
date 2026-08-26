## Goal

D29's first mechanism, standing alone: **discovery is by name, from
the compile-time lexer walk `call-after-define` already uses**. One
shared module classifies a test file — legacy (every top-level
`test_*` self-called), runner (none called), mixed (the shape that
must never pass) — and yields its ordered case list. The
`call-after-define` lint generalizes onto it: mixed fails, legacy and
runner both lint clean. Pure refactor plus that one rule change; the
compile seam (3IOCdHTM) and the migration (3IOCdooE) consume this
later and are not this slice.

## Evidence

Measured 2026-08-26 against main `8f34339e`; cited lines read today:

- **The walk to extract**: `_cli/lint.tl:201–241`
  (`check_call_after_define`) — token-exact: a top-level
  `local`-at-column-1 `function test_*`, its `end` found by
  `end_line_of` (`:153–186`, the depth walk with the `pending_do`
  flag), then the next non-blank line must match `^<name>%s*%(`.
  `end_line_of` has exactly one caller (`:216`), so both move
  together. `_cli/lint.tl` is 474 lines and this REMOVES ~90 —
  headroom recovered, no cap risk.
- **The rule it becomes**: D29
  (`docs/decisions/d29-tests-run-because-defined.md`) — "a file is
  all-or-nothing. every `test_*` self-called is legacy mode and
  compiles unchanged; none self-called is runner mode and gets the
  tail; MIXED is a lint failure. mixed is the one shape that must
  never pass, because its uncalled half would silently not run under
  legacy semantics."
- **The interim is safe without the seam**: with the lint accepting
  runner mode today, a runner-mode file still cannot slip through
  green — its uncalled `local function` is an unused local and
  `--check types` rejects it (warnings are errors; D29's context
  paragraph states this mechanism). The lint change is therefore
  landable before the seam exists.
- **The tree is 100% legacy**: 268 `*_test.tl` files (D29 counted
  2,870 call lines over 266 at its date), so the generalized rule
  changes no verdict on any committed file — `--make ci` green is the
  no-regression proof.
- **A second consumer already exists, wrong**: `_tool/testrun.tl:159–171`
  scans for case names with a line-based
  `line:match("^local function (test_[%w_]+)")` — not token-exact
  (a long-bracket fixture defining one would count). Rewiring testrun
  onto discovery is NOT this slice (its `.tests` sidecar consumers
  and report totals are 3IOCdZCA's); the module's home just has to
  admit that consumer: `_tool/` is embedded in the cosmic binary and
  is where testrun lives, so the module goes there.
- **Known walk bug, kept**: 3IP9ijhv — `end_line_of` miscounts a
  nested `record`/`enum` (their `end` closes the function's block
  early). The extraction moves the bug verbatim; fixing it is that
  item's.
- **Existing pins**: `_cli/lint_test.tl:213` asserts the
  `call-after-define` rule name; the file is 436 lines (headroom for
  the new mode tests). PR #1412 (in flight, 3ISNVQBg) also edits
  `_cli/lint.tl`'s wiring block — build this on a rebase after it
  merges; the overlap is the require/dispatch block only.

## Change

1. **`_tool/discover.tl`** (new) — the walk, extracted verbatim plus
   classification:
   - `record Case` — `name: string`, `line: integer` (the definition's
     line), `called: boolean` (a call on the next non-blank line after
     its `end`).
   - `record Discovery` — `cases: {Case}` in source order, and
     `mode: Mode` where `enum Mode` is `"legacy"`, `"runner"`,
     `"mixed"`, `"empty"` (no `test_*` definitions at all — helpers
     and `Example_*` files classify empty, not runner).
   - `discover(file: string, content: string, lines: {string}):
     Discovery` — mode is `legacy` when every case is called, `runner`
     when none is, `mixed` otherwise; `empty` when there are no cases.
   - `end_line_of` moves here with its doc comment and `pending_do`
     reasoning intact; export it only if the lint still needs it
     (expected: no other caller — keep it local).
2. **`_cli/lint.tl`** — `check_call_after_define` shrinks to a
   consumer: run `discover`; `empty`, `legacy` and `runner` return no
   diagnostics; `mixed` yields one diagnostic per UNCALLED case
   (rule name stays `call-after-define`), its message teaching D29's
   line: the file mixes modes, and the uncalled half would silently
   not run — call every test after its definition (legacy) or none
   (runner). The `_test.tl`-only scope and the helpers/`Example_*`
   exemption stay exactly as the current doc comment states.
3. **`_tool/discover_test.tl`** (new) — fixture-source tests: an
   all-called file is legacy with ordered cases and lines; a
   none-called file is runner; one-uncalled-of-two is mixed and the
   lint flags exactly the uncalled name; a helper (non-`test_`) and a
   quoted `local function test_x` inside a long bracket are not
   cases; a no-test file is empty; blank lines between `end` and the
   call still count as called (the current next-non-blank rule).
4. **`_cli/lint_test.tl`** — the existing call-after-define tests
   keep passing (message text may change; the `:213` rule-name assert
   must hold); add the two new-verdict cases at the lint level:
   all-uncalled lints clean, mixed does not.
5. **Doc surface**: `docs/guides/lint.md`'s call-after-define section
   gains the mode sentence (legacy or runner, never mixed), citing
   D29.

## Non-goals

- **No compile seam** — nothing appends the runner tail; a
  runner-mode file remains refused by `--check types` (unused local)
  until 3IOCdHTM, and that is the designed interim.
- **No testrun rewiring** — `_tool/testrun.tl`'s line-based scan
  stays; 3IOCdZCA owns the `.tests`/report half.
- **No migration** — no committed test file changes mode; 3IOCdooE.
- **No `end_line_of` bug fix** — 3IP9ijhv moves with the code,
  unfixed.
- **No `cosmic/test.tl` coupling** — 3IOCco6e (PR #1405, in check)
  owns the runner module; this slice must not touch `cosmic/**`.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS` — 268 legacy test files, no
  verdict changes.
- `grep -c "check_call_after_define\|end_line_of" _tool/discover.tl`
  ≥ 1 each of `discover` and `end_line_of` moved in (today the file
  does not exist); `grep -n "end_line_of" _cli/lint.tl` prints
  nothing (today `:153`, `:216`).
- `bin/cosmic --make test _tool/discover_test.tl _cli/lint_test.tl`
  ends `test: PASS (2 files)`.
- Mixed still fails, at the lint level: `_cli/lint_test.tl` carries a
  fixture asserting rule `call-after-define` on the uncalled name of
  a mixed file, and a runner-mode fixture asserting zero diagnostics
  (today: the same fixture would be flagged).
- `wc -l _cli/lint.tl` < 474 (the walk left) and every touched file
  ≤ 500.
- `git diff --name-only origin/main` lists exactly:
  `_cli/lint.tl`, `_cli/lint_test.tl`, `_tool/discover.tl`,
  `_tool/discover_test.tl`, `docs/guides/lint.md`, plus
  `.cosmic-coverage` for the new file's row (printed regen only).

## Enablement

none needed. The walk moves verbatim (no new checker-facing shape;
3IRRqpQi satisfied by construction); D29 is the settled decision the
rule cites; the one sequencing constraint — rebase on main after PR
#1412 merges, since both edit `_cli/lint.tl`'s wiring — is stated in
Evidence and costs a rebase, not a design.
