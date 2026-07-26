# 018 — `imports_of` matches `require` in comments and strings

severity: low
type: bug (false refusals)
area: `_make/validate.tl`

## issue

the import scanner's gmatch pattern matches `require(...)` as a substring
anywhere in the file: inside comments (`-- require("cmd.other.main")`),
inside string literals, and as a suffix of longer identifiers
(`myrequire(...)`). since `check_imports` *errors* on rule-violating
matches, a commented-out cross-`cmd` require or an internal-module name
mentioned in a docstring fails validation — a false refusal, not just noise.
the docstring admits only false *negatives* (computed requires), not false
positives.

## where

- `_make/validate.tl:209` — the gmatch pattern.
- `check_imports` — errors on matches against the reserved/internal/cmd
  rules.

## failure scenario

a developer comments out `local other = require("cmd.other.main")` while
debugging, or writes documentation mentioning `require("cosmic._x")` in a
string. `--make check` refuses the project with an internal-import error for
code that never runs.

## suggested fix

anchor the pattern to statement-shaped matches: require a word boundary
before `require` (reject a preceding identifier character), and strip line
comments before scanning (a cheap `gsub("%-%-[^\n]*", "")` — long comments
and strings are rarer; handle them if they bite). full tokenization is
overkill; matching what `deps.direct` does keeps the two scanners agreeing
(see also 032 — memoizing one shared scan is the structural fix).

## test to add

validator tests: a commented-out cross-cmd require passes; a
`myrequire("cmd.other.x")` call passes; a real cross-cmd require still
fails.
