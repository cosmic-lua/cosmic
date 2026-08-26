## Goal

G5 — adversarial verification, through the container `test runner:
tests run because they are defined` (3IOCIBGe). This is that
container's **phase 3**: the one lexer walk that says what a test file
IS and what cases it holds, extracted from the lint that currently
owns it, so the compile seam (3IOCdHTM), the runner tail and the
migration (3IOCdooE) all read the same answer instead of each
re-deriving it. `docs/decisions/d29-tests-run-because-defined.md` is
the contract; nothing here re-decides it.

## Evidence

Measured 2026-08-26 at main `1afdfb01`, from the repo root.

- **The walk exists once, inside a lint, and nothing else can reach
  it.** `_cli/lint.tl:200-241` is `check_call_after_define`: it bails
  unless the path ends `_test%.tl$`, lexes with `tl.lex`, and for every
  `local function test_*` at column 1 finds the definition's `end` and
  asks whether the next non-blank line is `<name>(`. Its block-depth
  helper is `_cli/lint.tl:152-185` (`end_line_of`), whose only caller
  is that rule (`grep -n 'end_line_of' _cli/ _tool/` → the definition
  and `_cli/lint.tl:215`). Neither is exported.
- **The `_tool/**` tree may require the lexer; only `_tool/lint.tl`
  may not.** `grep -rn 'require("tl")' _tool/` → `_tool/coverage/lines.tl:8`.
  `_tool/lint.tl:5-8`'s "no Teal compiler to require" describes that
  file's own purity, not the tree's, so a lexer-using discovery module
  under `_tool/` has precedent. `_tool/` is the right side of the line
  for the eventual consumers: `_tool/testrun.tl` runs test files
  (`wc -l` → **337**) and the compile seam is 3IOCdHTM's, while
  `_cli/lint.tl` already requires `_tool.lint` and can require one more.
- **The runner half of the contract has landed.** `cosmic/test.tl`'s
  `Case` (`:28-31`) is `{name: string, fn: function()}` — the shape a
  generated tail hands `main`. This module yields the SOURCE-side case
  list (a name and where it sits), not that record: a discovery walk
  has no functions to hand anybody.
- **The tree is entirely legacy, so the rule change is a widening with
  nothing to widen over.** `git ls-files '*_test.tl' | wc -l` → **267**
  files, `main` is green, and the rule as written today flags any
  `test_*` not called immediately — so every one of those 267 is
  legacy or holds no `test_*` at all. No file in the tree changes
  classification, and none changes diagnostics.
- **The rule's tests are the regression net and they are specific.**
  `grep -n 'call_after_define' _cli/lint_test.tl` → 8 hits across four
  tests at `:202`, `:221`, `:234` and `:247` — the runnable ones, the
  keywords-in-strings case, nested blocks, and the scoping to
  `_test.tl`. They call `lint.check_call_after_define(path, src,
  lines_of(src))` through the module's exported record, so keeping that
  name and signature keeps all four unchanged. `wc -l _cli/lint_test.tl`
  → **436**.
- **Headroom.** `wc -l _cli/lint.tl` → **466**, cap 500 — and this
  slice REMOVES from it: `end_line_of` (34 lines) and the body of
  `check_call_after_define` (about 30 of its 42), against a require
  line and a much shorter body. `_tool/discovery.tl` and
  `_tool/discovery_test.tl` are new, so each has the whole 500.
- **Coverage carries `_tool/**`.** `grep -n '_tool/lint.tl'
  .cosmic-coverage` → `["_tool/lint.tl"] = {["covered"] = 16,
  ["total"] = 17}` (line 126), and `_tool/coverage/baseline.tl:8-11` fails the
  gate when the file set drifts, so the new module needs
  `bin/cosmic --make coverage --baseline`.
- **The item's Context names a doc that is not in the tree.**
  `ls docs/design/test-runner.md` → no such file; it lives on the side
  branch `claude/cosmic-test-runner-rgb819`. Nothing below depends on
  it — this spec stands alone, and reading that branch is optional
  background, not an input.

## Change

Two new files, two edited, one regenerated floor.

### `_tool/discovery.tl` — new

A module header saying what discovery is for: one walk answers what a
test file is and which cases it holds, so the lint, the compile seam
and the migration read one answer instead of three. Move `end_line_of`
here from `_cli/lint.tl:152-185`, body and comment unchanged — it is
the block-depth walk the case scan needs and it has no other caller.

The exported types and the one function:

```teal
local record Case
  name: string
  line: integer
  called_at: integer | nil
end

local enum Mode
  "none"
  "legacy"
  "runner"
  "mixed"
end

local record Discovery
  mode: Mode
  cases: {Case}
end

scan: function(file: string, content: string, lines: {string}): Discovery
```

`scan` does exactly this:

1. `tl.lex(content, file)`; on nothing, return `{mode = "none",
   cases = {}}`. `scan` does NOT check the path — classification is a
   fact about the CONTENT, and it is the lint that decides which paths
   it cares about. This is the one behavioural difference from the
   walk as it stands, and it is what lets the seam call `scan` on a
   file it is about to compile.
2. For each `local function <name>` whose `local` token is at column 1
   and whose `<name>` matches `^test_`, in source order: `line` is the
   `local` token's line, and `called_at` is the line of the first
   non-blank line after the definition's `end` when that line matches
   `^<name>%s*%(`, else nil. Source order is the case order; the list
   is never sorted.
3. `mode` is derived from the cases, never asserted separately: no
   cases → `"none"`; every case has a `called_at` → `"legacy"`; no case
   has one → `"runner"`; otherwise → `"mixed"`.

### `_tool/discovery_test.tl` — new

Legacy mode (every `test_*` called on the line after its `end`), using
`cosmic.check`, with a local helper that splits a source string into
lines and calls `scan` at a fixture path — no file is written. Cover:
each of the four modes from a source string; source order preserved
with three cases; `line` and `called_at` are the real line numbers;
a blank line and a comment line between an `end` and its call still
count as called; a helper (`local function make_db`) and an
`Example_*` are not cases; a `test_*` nested inside another function
(not at column 1) is not a case; `test_*` written inside a string or a
comment is not a case; nested `for`/`while`/`do`/`if`/`repeat` blocks
inside a case body do not confuse the `end` search; and a file with no
`local function` at all is `"none"` with an empty list.

### `_cli/lint.tl` — the rule reads the module

`local discovery = require("_tool.discovery")` in the alphabetical
require block. Delete `end_line_of` and the token walk inside
`check_call_after_define`; the rule keeps its exported name, its
signature `(file, content, lines)` and its doc comment's first
paragraphs, and becomes:

- return `{}` unless `file:match("_test%.tl$")` — the path scoping
  stays in the rule, where it already is;
- `local found = discovery.scan(file, content, lines)`;
- return `{}` unless `found.mode == "mixed"`;
- one diagnostic per case whose `called_at` is nil, at that case's
  `line`, column 1, rule name `call-after-define` unchanged.

The message gains the reason the rule now fires: the file is half
migrated — some `test_*` are self-called and some are not — so name
the uncalled function and say to pick one mode for the whole file,
keeping the existing clause about a failing run naming the function.
Extend the doc comment to say what the rule now permits and why:
`legacy` and `runner` are both whole answers to D29 and both lint
clean; `mixed` is the only shape that cannot be, because a reader
cannot tell which half is the mistake.

**The hazard this opens, stated so it is not discovered later.**
Until the compile seam lands (3IOCdHTM), a runner-mode file's cases
are defined and never called, so `--make test` runs the file and
executes no test. That is not silent — `_tool/testrun.tl:289` prints
each file's case count, so such a file reports `0 test functions` —
and the tree holds no runner-mode file today. Do not add a second rule
or a temporary guard for it; the seam is the fix and it is filed.

### `_cli/lint_test.tl` — one added test

The four existing `call-after-define` tests (`:202`, `:221`, `:234`,
`:247`) must pass **unchanged** — they are the regression net for the
extraction. Add `test_call_after_define_permits_a_whole_mode`: a
source with two `test_*` and neither self-called yields no
diagnostics, and the same source with one of the two self-called
yields exactly one, naming the uncalled function.

### The committed floor

`bin/cosmic --make coverage --baseline`, then commit
`.cosmic-coverage` — it gains a row for `_tool/discovery.tl`. Never
hand-edit it. If any other ratchet complains, run exactly the regen
command its failure message prints and commit the result.

## Non-goals

- **No compile seam, no generated tail, no runner consumer.** Nothing
  calls `scan` in this slice but the lint. `_tool/testrun.tl`,
  `_make/testrun.tl`, `cmd/cosmic/main.tl` and the `.tests` format are
  untouched; that is 3IOCdHTM's and 3IOCdZCA's.
- **No test file in the tree migrates.** All 267 stay legacy;
  3IOCdooE owns the migration. A diff that edits a `*_test.tl` other
  than `_cli/lint_test.tl` is out of scope.
- **`cosmic/test.tl` is not touched**, and `Discovery.Case` is
  deliberately NOT `cosmic.test`'s `Case`: one names a source
  position, the other carries a function, and `_tool/**` may not be
  required from a `cosmic/**` module anyway.
- **The rule keeps its name, its exported signature and its
  `_test%.tl$` scoping.** `check_call_after_define` stays on
  `_cli.lint`'s record with the same three parameters, or the four
  existing tests stop being a regression net.
- **`end_line_of` moves; it does not change.** Its block-depth
  handling — the `pending_do` flag and its comment — is load-bearing
  and stays byte-identical.
- **No new lint rule and no `--check lint` CLI change.**
- **Frozen:** the `Diagnostic` record's fields; the `call-after-define`
  rule name, which `docs/guides/lint.md` documents; D29.

## Acceptance

Run from the repo root.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `bin/cosmic --make test _tool/discovery_test.tl _cli/lint_test.tl`
   passes, including the four pre-existing `call-after-define` tests
   and the new whole-mode one.
3. `git diff origin/main -- _cli/lint_test.tl | grep -c '^-'` prints
   `0` — the extraction added a test and removed none, which is what
   makes the existing four a regression net rather than a rewrite.
4. `grep -c 'local function end_line_of' _cli/lint.tl` prints `0` (it
   prints `1` today) and `grep -c 'local function end_line_of'
   _tool/discovery.tl` prints `1`.
5. `wc -l < _cli/lint.tl` prints less than `466`, its count today —
   this slice is a net removal from that file.
6. `wc -l < _tool/discovery.tl` and `wc -l < _tool/discovery_test.tl`
   each print at most `500`.
7. `git diff --name-only origin/main | grep -c '_test\.tl$'` prints
   `2` — only `_cli/lint_test.tl` and the new
   `_tool/discovery_test.tl`; no tree test migrates.
8. `git diff --name-only origin/main` prints exactly, in any order:

   ```text
   .cosmic-coverage
   _cli/lint.tl
   _cli/lint_test.tl
   _tool/discovery.tl
   _tool/discovery_test.tl
   ```

## Enablement

none needed, and its blocker cleared. Everything the implementer needs
is read above at real line numbers: the walk to move
(`_cli/lint.tl:200-241`), its helper (`_cli/lint.tl:152-185`), the
sole caller to rewrite (`_cli/lint.tl:215`), the four tests that must
survive unchanged (`_cli/lint_test.tl:202,221,234,247`), the precedent
for a lexer under `_tool/` (`_tool/coverage/lines.tl:8`), the case
count that proves the tree does not move (267 files, all legacy), and
the coverage regen command from the gate's own failure message. The
item's Context points at `docs/design/test-runner.md`, which is not in
the tree — it is optional background on a side branch, and nothing
above depends on it.
