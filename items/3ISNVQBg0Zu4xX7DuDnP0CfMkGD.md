## Goal

G3 — an honest type layer, no escape hatches. D30 defines a
`-- throws:` / `-- exits:` justification grammar for the three shapes a
`cosmic.*` module may throw or exit in, and nothing enforces it. This
slice adds the lint, the way `3IRTkNx1` (PR #1401) added
`assert-justify` after D23's amendment defined `-- assert:`. A
convention a gate does not enforce reads as enforced, which is worse
than no convention.

## Evidence

Measured 2026-08-26 at main `1afdfb01` (D30 landed as PR #1408), from
the repo root.

- **The tree already satisfies the rule, so this slice edits no
  `cosmic/**` source.** The census
  `git ls-files 'cosmic/*.tl' 'cosmic/**/*.tl' | grep -v '_test\.tl$\|_example\.tl$\|_benchmark\.tl$' | xargs grep -nE '(^|[^_[:alnum:]])error\(|os\.exit\('`
  (doc-comment and comment lines dropped) finds **19 sites in 7 files**
  outside `cosmic/check.tl` (14 sites, D23's module) and
  `cosmic/rand.tl` (6, D22's): `cosmic/searcher.tl` 6,
  `cosmic/quicksand/box/run.tl` 5, `cosmic/hash.tl` 3,
  `cosmic/child/init.tl` 2, and one each in `cosmic/coverage/init.tl`,
  `cosmic/teal.tl`, `cosmic/init.tl`. Every one carries the marker its
  site kind demands — `-- throws:` on all 11 `error(` lines,
  `-- exits:` on all 8 `os.exit(` lines, trailing or on the line
  directly above — verified site by site against the merged tree. So a
  correct lint is green on `main` the moment it lands, and any
  `cosmic/**` path appearing in this slice's diff means the rule is
  wrong, not the tree.
- **`git ls-files 'cosmic/*_benchmark.tl' 'cosmic/**/*_benchmark.tl'`
  is empty**, so the scope predicate's treatment of benchmarks is
  untestable against the tree and must be settled by the fixture tests
  instead.
- **`assert-justify` is the working template, one rule file over.**
  `_cli/assert_lint.tl:217-260` is `check_assert_justification`: it
  bails unless `is_library_source(file)`, lexes with `tl.lex`, walks
  the tokens, skips a name preceded by `.` or `:`, requires the next
  token to be `(`, dedupes per line with a `seen` table, and asks
  `style.is_justified(lines, t.y, "assert")` for the comment. The
  lexer walk is what makes the rule usable: a naive grep also matches
  `cosmic/_teal_engine.tl`'s `process_error(` calls, which return a
  value and throw nothing, and every `error(` inside a string or doc
  comment.
- **The marker reader already takes the marker as an argument.**
  `_tool/lint.tl:46-63` — `is_justified(lines, y, marker)` builds
  `"%-%- " .. marker .. ": %S"` and accepts it trailing on the line or
  alone on the line above. `"throws"` and `"exits"` need nothing added
  to it. `wc -l _tool/lint.tl` → **70**.
- **The scope predicate is the one thing that would be copied.**
  `_cli/assert_lint.tl:202-215` defines `is_library_source` as a local
  and does not export it; `grep -c 'is_library_source'
  _cli/assert_lint.tl` → **2** (the definition and its one call). Its
  doc comment records why `/cosmic/` is deliberately not matched as
  well: the repository root directory is itself named `cosmic`, so
  that pattern would sweep the whole tree for an absolute path.
  `_tool/lint.tl`'s own header already states the rule for where such
  a helper belongs — "The lexer walks that FIND the sites stay in
  `_cli`, one per rule; they share this reader rather than each
  carrying a copy of it."
- **Wiring costs about seven lines in a file with 34 to spare.**
  `wc -l _cli/lint.tl` → **466**, cap 500. Each rule is wired as a
  `require` at the top (`:17-25`, alphabetical), a three-line
  `for _, d in ipairs(...) do` block inside the `path:match("%.tl$")`
  arm (`:386-417`), one field on the `LintModule` record (`:434-450`)
  and one entry in `M` (`:452-464`).
- **Every rule has a section in the shipped guide.**
  `grep -n '^## ' docs/guides/lint.md` lists `file-length`,
  `cast-justify`, `assert-justify`, then the rest alphabetically
  through `return-assert` and `visibility`. `wc -l
  docs/guides/lint.md` → **311**, 189 lines of headroom. Nothing
  ratchets rule names against that file — `_build/guides_test.tl:27`
  gates only `docs/guides/make.md` — so the section is convention, not
  a gate, and is written because the diagnostic message points readers
  at `guide.lint`.
- **Coverage carries `_cli/**`, so a new file there moves a committed
  floor.** `grep -n '_cli/assert_lint' .cosmic-coverage` →
  `["_cli/assert_lint.tl"] = {["covered"] = 95, ["total"] = 102}`.
  `_tool/coverage/baseline.tl:8-11` fails the gate when the file set
  drifts, and `bin/cosmic --make coverage --baseline` rewrites it.
- **`grep -rn 'throw-justify' _cli/ docs/` returns nothing today**, so
  every count in Acceptance starts at 0.

## Change

Five hand-edited files plus one regenerated floor. **No `cosmic/**`
source is touched** — see Evidence.

### `_tool/lint.tl` — the scope predicate joins the marker reader

Move `is_library_source` here from `_cli/assert_lint.tl`, body
unchanged (`file:match("^cosmic/")` and not `_test%.tl$` /
`_example%.tl$`), keeping its doc comment including the paragraph on
why `/cosmic/` is not matched. Export it beside `is_justified`, and
extend the module header's paragraph about the shared marker reader to
say the library-source predicate is shared for the same reason: two
rules ask the same question about a path and a second copy is drift
waiting to happen. Nothing else in this file moves — not
`check_file_length`, not `DEFAULT_FILE_LINES`, not `is_justified`.

### `_cli/assert_lint.tl` — use the shared predicate

Delete the local `is_library_source` definition and call
`style.is_library_source(file)` at its one call site in
`check_assert_justification`. `style` is already required at the top.
No other change: `check_return_assert`, the module header, the
`AssertLintModule` record and `M` all stay exactly as they are.

### `_cli/throw_lint.tl` — new, the rule

A module header stating what D30 licenses and why a lexer walk rather
than a grep (name `process_error(` as the concrete false positive).
One exported function:

```teal
check_throw_justification: function(file: string, content: string,
  lines: {string}): {Diagnostic}
```

Rule name in every diagnostic: `throw-justify`. Behaviour, in order:

1. Return `{}` unless `style.is_library_source(file)`.
2. Return `{}` for exactly `cosmic/check.tl` and `cosmic/rand.tl` —
   module-level exemptions recorded in D23 and D22, which is why those
   two carry no per-site comments. Match the path exactly; no prefix
   or pattern match.
3. `tl.lex(content, file)`; return `{}` when it yields nothing, the
   way `check_assert_justification` does.
4. Walk the tokens. A site is either:
   - a **throw**: an identifier token `error`, not preceded by `.` or
     `:`, followed by `(`. Its marker is `throws`.
   - an **exit**: an identifier token `exit` preceded by `.`, which is
     preceded by an identifier token `os`, and followed by `(`. Its
     marker is `exits`.
5. Dedupe per (line, marker), not per line — one comment covers
   however many sites of the same kind share a line, the way one
   `-- cast:` covers a line's casts.
6. For each surviving site, `style.is_justified(lines, y, marker)`.
   When it is false, emit a `Diagnostic` with `rule = "throw-justify"`,
   the site's line and column, and a message that names **the marker
   that site needs** (`-- throws:` for a throw, `-- exits:` for an
   exit), says a `cosmic.*` module may throw or exit only where no
   caller could receive the value, and ends by pointing at
   `cosmic --docs guide.lint` — the same three parts
   `assert-justify`'s message has.

The marker is chosen by site kind and the other marker does not
satisfy it: `-- exits:` on an `error(` line is a miss, and so is the
reverse. That is D30's grammar, and stating it loosely would let the
two drift into interchangeable noise.

### `_cli/throw_lint_test.tl` — new

Legacy mode (every `test_*` called on the line after its `end`), using
`cosmic.check`, following `_cli/assert_lint_test.tl:107-114`'s helper shape: a
local helper that splits a source string into lines and calls
`check_throw_justification` at a chosen path. Fixture paths are
strings, so no file is written. The tests:

- an unjustified `error(` in a library path is flagged once, with
  `rule == "throw-justify"`, the right line, and a message containing
  `-- throws:` and `guide.lint`;
- an unjustified `os.exit(` likewise, with `-- exits:` in the message;
- a trailing `-- throws: <reason>` justifies, and so does one on the
  line above;
- a bare `-- throws:` with no reason after it does NOT justify (the
  `%S` in `is_justified`);
- the WRONG marker does not justify — `-- exits:` on an `error(` line
  is still flagged, and `-- throws:` on an `os.exit(` line is still
  flagged;
- `error` reached through a field or method (`x.error(...)`,
  `t:error(...)`) is not a site, and neither is `process_error(...)`;
- `error` and `os.exit` inside a string constant or a comment are not
  sites;
- a test path (`cosmic/foo_test.tl`), an example path
  (`cosmic/foo_example.tl`) and a path outside `cosmic/`
  (`_cli/foo.tl`) all yield no diagnostics;
- `cosmic/check.tl` and `cosmic/rand.tl` yield no diagnostics for an
  unjustified site;
- two unjustified `error(` calls on one line yield ONE diagnostic, and
  an `error(` and an `os.exit(` on one line yield TWO.

### `_cli/lint.tl` — wire it in

`local throw_lint = require("_cli.throw_lint")` in the alphabetical
require block; a `for _, d in ipairs(throw_lint.check_throw_justification(path, content, lines)) do`
block beside the `assert_lint.check_assert_justification` one inside
the `path:match("%.tl$")` arm; the matching field on the `LintModule`
record and entry in `M`, both named `check_throw_justification`.
Nothing else in this file moves.

### `docs/guides/lint.md` — one section

`## throw-justify`, placed alphabetically between `## return-assert`
and `## visibility`. State the rule (a `cosmic.*` module may throw or
exit only where no caller could receive the value), the three shapes
D30 licenses in one line each, the two markers and which site kind
takes which, the trailing-or-line-above acceptance, and the two
module-level exemptions. Link D30 the way the neighbouring sections
link their records.

### The committed floor

`bin/cosmic --make coverage --baseline`, then commit
`.cosmic-coverage` — it gains a row for `_cli/throw_lint.tl`. Never
hand-edit it. If any other ratchet complains, run exactly the regen
command its failure message prints and commit the result; that is in
scope and is the only sanctioned way to move a floor.

## Non-goals

- **No `cosmic/**` source changes.** The tree already satisfies the
  rule (Evidence), so a diff that edits a library site means the rule
  is wrong. Acceptance step 7 checks this directly. In particular
  `cosmic/check.tl` and `cosmic/rand.tl` are not annotated — their
  exemptions are module-level and already recorded.
- **No decision-record change.** D30, D23 and D22 are the contract;
  this enforces D30 and amends nothing. `docs/decisions/**` is not
  touched, and neither is `AGENTS.md`, whose bullet D30 already
  extended.
- **`assert-justify` and `cast-justify` do not change behaviour.** The
  only edit to `_cli/assert_lint.tl` is calling the moved predicate;
  its diagnostics, message text and rule name are frozen, which
  Acceptance step 3 checks by running that rule's own tests.
- **`is_justified` is not touched**, and no second justification
  marker is invented: `throws` and `exits` are D30's two, and the
  reader already takes the marker as an argument.
- **No new lint flag, no `--check lint` CLI change, no new rule
  beyond `throw-justify`**, and no widening of the rule to
  `error(`/`os.exit(` outside `cosmic/**` — the internal tree is not
  under D23 or D30 and this rule says nothing about it.
- **No other helper moves into `_tool/lint.tl`.** One predicate, for
  the one reason stated.
- **Frozen:** the `Diagnostic` record's fields; the
  `-- cast:` / `-- assert:` grammars and their lints; `tl.lex` usage;
  `_build/guides_test.tl`'s scope.

## Acceptance

Run from the repo root.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `bin/cosmic --make test _cli/throw_lint_test.tl` passes, including
   the wrong-marker, exempt-module and one-line-two-kinds cases named
   in Change.
3. `bin/cosmic --make test _cli/assert_lint_test.tl _tool/lint_test.tl`
   passes — the predicate move left `assert-justify` and the pure
   checks alone.
4. `grep -c 'throw-justify' _cli/throw_lint.tl` prints at least `1`
   and `grep -c 'throw-justify' docs/guides/lint.md` prints at least
   `1` (both print `0` today).
5. `grep -c 'local function is_library_source' _cli/assert_lint.tl`
   prints `0` (it prints `1` today) and
   `grep -c 'is_library_source' _tool/lint.tl` prints at least `2`
   (it prints `0` today).
6. `wc -l < _cli/lint.tl`, `wc -l < _cli/throw_lint.tl`,
   `wc -l < _cli/throw_lint_test.tl` and `wc -l < _tool/lint.tl` each
   print at most `500` (`_cli/lint.tl` is `466` today and gains about
   seven lines; `_tool/lint.tl` is `70`).
7. `git diff --name-only origin/main | grep -c '^cosmic/'` prints `0`
   — the rule is green on the tree as it stands, with no library site
   edited to make it pass.
8. `git diff --name-only origin/main` prints exactly, in any order:

   ```text
   .cosmic-coverage
   _cli/assert_lint.tl
   _cli/lint.tl
   _cli/throw_lint.tl
   _cli/throw_lint_test.tl
   _tool/lint.tl
   docs/guides/lint.md
   ```

## Enablement

none needed, and its blocker has landed: D30 is on `main` as
`1afdfb01`'s ancestor (PR #1408), so the grammar exists in the tree
before this demands it. Everything the implementer needs is read above
at real line numbers — the template rule at
`_cli/assert_lint.tl:217-260`, the marker reader at
`_tool/lint.tl:46-63`, the predicate to move at
`_cli/assert_lint.tl:202-215`, the four wiring points in
`_cli/lint.tl`, the guide's section ordering, and the coverage regen
command from the gate's own failure message. The census command and
its 19-site result are above so a claiming session can re-run it in
seconds and see whether the tree still satisfies the rule before
building.
