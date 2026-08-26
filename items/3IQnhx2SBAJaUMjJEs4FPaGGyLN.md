## Goal

G3 — an honest type layer. D23's amended rule licenses `assert` on a
`cosmo.*` return whose declared `| nil` cannot occur, and the carried
`narrow-assert-decl` patch declares `assert` as ONE return so the
licensed shape composes. In RETURN position that declaration is a lie:
Lua's `assert` returns all of its arguments, so a function written
`return assert(x, msg)` type-checks as one-valued and is two-valued at
runtime. This slice makes the trap a lint diagnostic instead of a
runtime surprise.

## Evidence

Hit while implementing 3IPktATw (PR #1386). `cosmic/fs/path.tl`'s
`join` was written `return assert(joined, "path.join: every argument
was nil")`. `--make ci` passed; the compiled tree then failed at
runtime in `cosmic/fs/find.tl:318` with

```text
bad argument #2 to 'insert' (number expected, got string)
```

because `table.insert(out, join(dir, entry))` expanded to the
three-argument `table.insert`. It broke `o/bin/cosmic` itself — the
built binary could no longer discover its own project root — so the
recovery needed a rebuild from the pin. The fix that landed was a
comment telling the next author to `assert` as a statement and return
the local; nothing checks it.

Measured 2026-08-26 against main `3053b87d`:

- `git ls-files '*.tl' | xargs grep -n "return assert("` → no matches.
  The tree has ZERO instances today, so this rule is preventive and
  cannot have a false positive to triage on arrival.
- `git ls-files '*.tl' | xargs grep -h -- "-- assert:" | wc -l` → `0`.
  D23's licensed shape has no live site either: the six dance sites
  retired with the cosmos pin bump (PR #1395). The hazard is entirely
  in the sites D23 licenses NEXT.
- `check.must` does not share the trap, and this settles the open
  question the capture left. `cosmic/check.tl:176-187` is an ordinary
  Teal `function must<T>(value: T | nil, err?: string |
  errors.Failure): T` whose body ends `return value` — one declared
  return, one runtime value. The 11 `return check.must(...)` sites
  (`git ls-files '*.tl' | xargs grep -c "return check\.must(" | awk
  -F: '$2>0'`, summed) are correct as written and this slice must not
  flag them.
- `wc -l < _cli/lint.tl` → `466`, 34 lines of headroom under the
  500-line cap. That is why the rule gets its own module rather than
  joining the composition file.
- `wc -l < _cli/reads_lint.tl` → `80`, and `wc -l <
  _cli/reads_lint_test.tl` → `59`: the shape this slice copies.

## Change

Add one lexer-based lint rule, `return-assert`, in a new module, and
compose it into the existing gate.

**1. New `_cli/assert_lint.tl`** — modelled on `_cli/reads_lint.tl`:
requires `_tool.lint` for `Diagnostic` and `tl` for `tl.lex`, exports
one function

```teal
local function check_return_assert(file: string, content: string): {Diagnostic}
```

Token-exact via `tl.lex(content, file)`, so an `assert` quoted inside a
string or a comment never counts. It flags exactly this shape and
nothing else: a `return` keyword whose FINAL expression is a direct
call to the bare global `assert` with TWO OR MORE top-level arguments.

The three qualifiers are each load-bearing, and each needs its own
test:

- **final expression only.** Lua expands only the last expression of a
  return list, so `return assert(x, msg), y` truncates `assert` to one
  value and is safe. Do not flag it.
- **two or more arguments.** `return assert(x)` returns one value at
  runtime and is safe. Count arguments at the call's top level —
  commas nested inside `(`/`)`, `[`/`]`, `{`/`}` do not separate
  arguments. `_cli/returns.tl`'s `skip_balanced` is the existing
  helper for that walk; require it or write the equivalent, whichever
  keeps this module under the cap.
- **bare global.** Flag `assert(`; do not flag `x.assert(` or
  `x:assert(`. A `(` immediately before the `assert` token —
  `return (assert(x, msg))` — truncates to one value and is safe;
  do not flag it.

The diagnostic: `rule = "return-assert"`, `line` and `col` from the
`assert` token, and a message naming both halves of the mismatch and
the fix, in the tree's diagnostic voice — it must contain the literal
substrings `declares one return` and `assert as a statement`, which is
what the test asserts on.

**2. New `_cli/assert_lint_test.tl`** — `test_*` functions, each
called on the line after its `end`, per AGENTS.md. Cases: the flagged
shape; `return assert(x)`; `return assert(x, msg), y`; `return
(assert(x, msg))`; `return check.must(x, msg)`; `t.assert(x, msg)` in
return position; an `assert(x, msg)` inside a string literal; and a
statement-position `assert(x, msg)` on its own line. Fixture sources
are inline strings in the test, the way `_cli/reads_lint_test.tl`
holds its own.

**3. `_cli/lint.tl`** — three lines and one loop, nothing else: a
`local assert_lint = require("_cli.assert_lint")` beside the requires
at lines 20–24; a
`for _, d in ipairs(assert_lint.check_return_assert(path, content)) do`
loop in `lint_file`'s `path:match("%.tl$")` block, next to the
`returns.check_fallible_returns` loop at line 417; and the matching
`check_return_assert` field on the `LintModule` record and entry in
`M`, mirroring how `check_reads_declaration` is re-exported.

**4. `docs/guides/lint.md`** — a `## return-assert` section between
`## nil-declaration` and `## visibility`, following the shape of the
sections around it: what the rule catches, why the checker cannot,
and the fix. The bad shape and the fix both go in ```text fences, NOT
```teal — `_build/snippets_test.tl` compiles and format-checks every
`teal` fence at full strictness, and both snippets here are fragments.

**5. The coverage ratchet.** A new file adds rows to
`.cosmic-coverage`. When the coverage stage complains, run exactly the
regen command its failure message prints and commit the result; do not
weaken the gate any other way.

## Non-goals

- **`3p/tl/tl_patch.tl` is not touched.** Re-declaring `assert` as
  `function<A, B>(A | nil, ? B, ...: any): A, B` so the checker sees
  the real arity is the other candidate countermeasure, and it is
  rejected here: the declared second return would then expand in every
  last-argument position too, so `table.insert(parts, assert(chunk))`
  — the composition the patch exists to enable, quoted as supported in
  `cosmic/check.tl:161-163` and in AGENTS.md — would start type-checking
  as a three-argument `table.insert`. That is a tree-wide risk against
  a trap with zero live instances. If it is ever worth re-opening, it
  is a separate item with its own census.
- **The `-- assert:` justification rule is not this slice's** — that is
  board item 3IRTkNx1, which lands after this one and adds its rule to
  the same new `_cli/assert_lint.tl`. Do not write it here, and do not
  restructure the module in anticipation of it.
- **No other lint rule changes**, and no reformatting of `_cli/lint.tl`
  beyond the four insertions named above. The diagnostic format
  (`file:line: rule: message`) and the `lint: PASS (N files)` verdict
  line are frozen — downstream reads them.
- **No `cosmic/**` source changes.** The tree has no site to fix; a
  green `--make lint` over the unchanged tree is part of the proof.
- **`check.must` is not flagged and not changed.** It is a real
  one-value function; see Evidence.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _cli/assert_lint_test.tl` ends
  `test: PASS (1 file)`.
- `bin/cosmic --make lint` ends `lint: PASS` — the rule fires on
  nothing in this tree (today: `git ls-files '*.tl' | xargs grep -c
  "return assert(" | awk -F: '$2>0'` prints nothing).
- `grep -c 'return-assert' _cli/assert_lint.tl` prints `1` or more,
  and `grep -c '^## return-assert' docs/guides/lint.md` prints `1`.
- `wc -l < _cli/assert_lint.tl` and `wc -l < _cli/lint.tl` each print a
  number ≤ 500 (today `_cli/lint.tl` is 466).

## Enablement

none needed. The module shape, its composition point and its test
shape all exist in the tree: `_cli/reads_lint.tl` is the model module,
`_cli/lint.tl`'s `lint_file` is the one composition point, and
`_cli/returns.tl`'s `skip_balanced` is the balanced-group walk. The
conventions that bind are AGENTS.md's, unchanged.
