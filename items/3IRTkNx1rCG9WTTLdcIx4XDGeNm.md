## Goal

G3 — an honest type layer, no escape hatches. D23's amendment licenses
a `cosmic.*` module to `assert` a `cosmo.*` binding return whose
declared `| nil` is unreachable for the arguments that call passes,
**provided the assert carries a trailing `-- assert: <why the nil
cannot occur>` comment**. The proviso is the whole safety of the
licence and nothing enforces it, where the parallel `-- cast:`
convention has had the `cast-justify` lint since it was written. This
slice gives the assert convention the same enforcement.

## Evidence

Measured 2026-08-26 against main `14ff1d1d` (with #1399 landed).

- **The convention has zero live instances, so this is insurance, not
  a burn-down.** `git ls-files '*.tl' | xargs grep -h -- "-- assert:"
  | wc -l` → `0`. PR #1395 retired the six dance sites by making the
  upstream contracts exact. The rule must therefore be green on
  arrival and stay green until the next argument-dependent union.
- **A grep-based rule would be wrong 23 times out of 23.** Over the
  114 non-test, non-example `.tl` files under `cosmic/`
  (`git ls-files 'cosmic/*' | grep '\.tl$' | grep -v '_test\.tl$' |
  grep -v '_example\.tl$' | wc -l` → `114`), the command
  `... | xargs grep -c 'assert *('` sums to **23** hits, and every one
  of them is invisible to a lexer:
  - 22 are inside comments — `cosmic/_teal_hints.tl:13,64,66`,
    `cosmic/net/init.tl:252-253`, `cosmic/poll.tl:87`,
    `cosmic/quicksand/box/init.tl:16`, `cosmic/quicksand/netns.tl:12,
    13,17,18`, `cosmic/quicksand/proc.tl:143-144`,
    `cosmic/sandbox/init.tl:13`, `cosmic/sqlite/init.tl:16-22,149` —
    mostly `---` doc-comment example snippets.
  - 2 are inside double-quoted string constants returned as hint text,
    `cosmic/_teal_hints.tl:76` and `:115`.
  - 1 is inside a long-bracket string: `cosmic/embed/init.tl:186`,
    `local chunk = assert(loadfile("/zip/main.user.lua"))`, which is a
    line of the `WRAP_MAIN` payload (`cosmic/embed/init.tl:178-188`)
    that gets written into a generated artifact, not code this module
    runs.

  So the rule fires on **zero** sites today, and a token-exact walk is
  what makes that true. Verified by reading each of the 23 lines.
- **No allowlist is needed.** D22/D23's sanctioned throwers do not use
  `assert` at all: `grep -n 'error(\|assert(' cosmic/check.tl` → 12
  hits, all `error(msg, 2)`; the same over `cosmic/rand.tl` → 6 hits,
  all `error(...)`. Nothing in either module would be flagged, so the
  rule needs no `COSMO_REQUIRE_ALLOWLIST`-style table.
- **The model rule.** `check_cast_justification` is
  `_cli/lint.tl:70-91`: it collects `as` token lines via `cast_lines`
  (`_cli/lint.tl:34-51`, a `tl.lex` walk) and asks
  `is_justified(lines, y)` (`_cli/lint.tl:56-64`) whether the line, or
  the line directly above it, carries `-- cast: <reason>`.
- **`is_justified` has exactly one caller.** `grep -n 'is_justified'
  _cli/lint.tl` → `57` (the definition) and `77` (the one call). That
  is what makes moving it cheap.
- **Capacity.** `wc -l` → `_cli/lint.tl` `472` (28 lines of headroom,
  which is why the rule cannot live there), `_cli/assert_lint.tl`
  `196` (304 lines of headroom), `_cli/assert_lint_test.tl` `100`,
  `_tool/lint.tl` `43`, `_tool/lint_test.tl` `53`,
  `docs/guides/lint.md` `271`.
- **`_cli/lint.tl` already requires both modules it needs:**
  `local style = require("_tool.lint")` at `:23` and
  `local assert_lint = require("_cli.assert_lint")` at `:20`. The
  dependency runs `_cli/lint.tl → _cli/assert_lint.tl → _tool/lint.tl`
  in one direction only, so `_tool/lint.tl` is the one place both
  rules can share a helper without a require cycle.
- **`--make lint` is green on this tree today:** `bin/cosmic --make
  lint` → `lint: PASS (628 files)`.

## Change

Add one lint rule, `assert-justify`, to the module #1399 created, and
lift the justification-comment reader both rules need into the module
they both already require.

**1. `_tool/lint.tl`** — add the shared reader. Move
`_cli/lint.tl:56-64`'s `is_justified` here and give it the marker word
as a third parameter:

```teal
local function is_justified(lines: {string}, y: integer,
    marker: string): boolean
```

Body as it stands today, with the two hardcoded `"%-%- cast: %S"`
patterns built from `marker` instead (`"%-%- " .. marker .. ": %S"`,
and the same with the `^%s*` anchor for the line above). Export it
from the returned table beside `check_file_length`. Extend the module
header: it says the pure checks need "nothing but the file's lines",
which is exactly what this reader needs — say that the marker readers
for `-- cast:` and `-- assert:` live here for that reason, while the
lexer walks that find the sites stay in `_cli`.

**2. `_cli/lint.tl`** — delete the local `is_justified` and change its
one call site (`:77`) to `style.is_justified(lines, y, "cast")`. No
other change to this file, and no new require: `style` is already
bound at `:23`.

**3. `_cli/assert_lint.tl`** — add the rule beside `check_return_assert`:

```teal
local function check_assert_justification(file: string, content: string,
    lines: {string}): {Diagnostic}
```

- **Scope by path, first thing.** Return `{}` unless
  `file:match("^cosmic/")`, and return `{}` when the path matches
  `_test%.tl$` or `_example%.tl$`. Use `^cosmic/` and nothing else —
  `_cli/visibility.tl:25` scopes the same way, and the repo-relative
  paths `--make lint` walks are what the gate passes. Do NOT also
  match `/cosmic/`: the repository root directory is itself named
  `cosmic`, so that pattern would sweep the entire tree in an
  absolute-path invocation.
- **Find the sites token-exactly** via `tl.lex(content, file)`, the
  way `check_return_assert` already does in this module: an `assert`
  token whose `kind` is `identifier`, immediately followed by `(`, and
  whose PRECEDING token is neither `.` nor `:` — so `x.assert(v)` and
  `x:assert(v)` are not the global. One diagnostic per LINE, not per
  token: a line with two asserts takes one `-- assert:` comment, which
  is how `cast_lines` dedupes by `t.y` today.
- **Ask the shared reader** whether that line carries its
  justification: `style.is_justified(lines, y, "assert")`.
- The diagnostic: `rule = "assert-justify"`, `line` and `col` from the
  `assert` token, and a message in the voice of `cast-justify`'s —
  naming that a library `assert` throws, that D23 licenses it only for
  a `cosmo.*` return whose `| nil` is unreachable for the arguments
  passed, and that the licence needs a trailing `-- assert: <why the
  nil cannot occur>` (or one on the line above). It must contain the
  literal substrings `-- assert:` and `guide.lint`, which is what the
  test asserts on.
- Re-export it: add `check_assert_justification` to the
  `AssertLintModule` record and to `M`, beside `check_return_assert`.
- Extend the module header, which today describes only arity: say the
  module now holds both assert rules — the arity trap and the
  justification proviso.

**4. `_cli/lint.tl`, composition** — one require-free loop in
`lint_file`'s `path:match("%.tl$")` block, directly after the existing
`assert_lint.check_return_assert` loop:

```teal
for _, d in ipairs(assert_lint.check_assert_justification(path, content,
    lines)) do
  diagnostics[#diagnostics + 1] = d
end
```

plus the matching `check_assert_justification` field on the
`LintModule` record and entry in `M`, mirroring how
`check_return_assert` is re-exported.

**5. `_cli/assert_lint_test.tl`** — add `test_*` functions, each called
on the line after its `end`, per AGENTS.md. The fixture sources are
inline strings, as the file's existing cases are; the helper must pass
a `cosmic/`-prefixed path (the existing `diagnose` helper hardcodes
`"fixture.tl"`, so add a second helper rather than changing it — the
`return-assert` cases must keep firing on a non-`cosmic/` path). Cases:

- an unjustified `assert(v)` in a `cosmic/` path is flagged, at the
  right line, with `rule == "assert-justify"`;
- the same line carrying a trailing `-- assert: <reason>` is not;
- the same line with `-- assert: <reason>` on the line ABOVE is not;
- a bare `-- assert:` with no reason after it IS still flagged (the
  `%S` in the pattern is what demands one);
- the same unjustified `assert(v)` at a `_cli/` path is not flagged
  (scope), and at a `cosmic/..._test.tl` path is not flagged;
- `x.assert(v)` and `x:assert(v)` in a `cosmic/` path are not flagged;
- an `assert(v)` inside a double-quoted string is not flagged;
- an `assert(v)` inside a `[[ ]]` long bracket is not flagged — this
  is `cosmic/embed/init.tl:186`'s shape and the reason the rule is
  lexer-based;
- two asserts on one line yield ONE diagnostic.

**6. `_tool/lint_test.tl`** — add a `test_*` for the moved reader:
justified on the line, justified above, unjustified, and that the
marker discriminates (a `-- cast:` comment does not justify an
`"assert"` query, and the reverse).

**7. `docs/guides/lint.md`** — a `## assert-justify` section
immediately after `## cast-justify` (which ends at `:64`, before
`## call-after-define` at `:65`), following the shape of the sections
around it: what the rule catches, why the checker cannot, and the fix.
Point at D23 as the licence and at `## cast-justify` as the twin. Both
snippets go in ```text fences, NOT ```teal — `_build/snippets_test.tl`
compiles and format-checks every `teal` fence at full strictness, and
a licensed-assert fragment is not a compilable module.

**8. The coverage ratchet.** This adds no file, but it moves the
covered/total rows for `_cli/assert_lint.tl`, `_cli/lint.tl` and
`_tool/lint.tl`. If the coverage stage complains, run exactly the
regen command its failure message prints and commit the result; do not
weaken the gate any other way.

## Non-goals

- **No `cosmic/**` source changes, and no `-- assert:` comments added
  anywhere.** The census above found zero lexer-visible sites, so
  there is nothing to fix; a green `--make lint` over the unchanged
  library tree is part of the proof. In particular
  `cosmic/embed/init.tl:186` is a line of generated payload inside a
  long bracket and must not be touched or annotated.
- **No allowlist table.** `cosmic/check.tl` and `cosmic/rand.tl` throw
  with `error(...)` and hold no `assert(` call; if a sanctioned module
  ever needs one, the `-- assert:` marker is the mechanism. Do not add
  a per-file exemption table "for later".
- **No behaviour change to `cast-justify`.** The move is a refactor:
  the rule must fire on exactly what it fires on today, and
  `_cli/lint_test.tl`'s existing cast cases are the proof. Do not
  rename the rule, change its message, or widen its scope.
- **No change to `check_return_assert`** or its existing tests in
  `_cli/assert_lint_test.tl`. This slice adds a second rule to the
  module; it does not revise the first.
- **`3p/tl/tl_patch.tl` is not touched**, and neither is
  `docs/decisions/d23-check-throws.md`. This slice enforces D23 as it
  stands; changing what D23 licenses is the `decide` skill's business,
  not a lint's.
- **No widening beyond `cosmic/**` library source.** `_cli/`, `_make/`,
  `_tool/`, `_build/`, `cmd/` and every `*_test.tl` / `*_example.tl`
  are out of scope — D23 governs `cosmic.*` modules, and tests assert
  freely by design (AGENTS.md's test pattern is built on `assert`).
- **The diagnostic format is frozen**: `file:line: rule: message`, and
  the `lint: PASS (N files)` verdict line. Downstream reads both.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make lint` ends `lint: PASS` — the new rule fires on
  nothing in this tree (today: `lint: PASS (628 files)`).
- `bin/cosmic --make test _cli/assert_lint_test.tl` ends
  `test: PASS (1 file)`.
- `bin/cosmic --make test _tool/lint_test.tl` ends
  `test: PASS (1 file)`.
- `bin/cosmic --make test _cli/lint_test.tl` ends `test: PASS (1 file)`
  — `cast-justify` unchanged through the move.
- `grep -c 'assert-justify' _cli/assert_lint.tl` prints `1` or more
  (today `0`), and `grep -c '^## assert-justify' docs/guides/lint.md`
  prints `1` (today `0`).
- `grep -c 'local function is_justified' _cli/lint.tl` prints `0`
  (today `1`) and `grep -c 'local function is_justified'
  _tool/lint.tl` prints `1` (today `0`) — the reader moved rather than
  being copied.
- `wc -l < _cli/assert_lint.tl`, `wc -l < _cli/lint.tl` and
  `wc -l < _tool/lint.tl` each print a number ≤ 500 (today `196`,
  `472`, `43`).

## Enablement

none needed. Every piece exists in the tree: `_cli/lint.tl:70-91`'s
`check_cast_justification` is the model rule and `:34-51`'s
`cast_lines` the model lexer walk; `_cli/assert_lint.tl` is the home
module and `_cli/assert_lint_test.tl` the test file, both landed by
#1399; `_tool/lint.tl` is required by both rule modules already, so
the shared reader needs no new edge. The conventions that bind are
AGENTS.md's, unchanged.
