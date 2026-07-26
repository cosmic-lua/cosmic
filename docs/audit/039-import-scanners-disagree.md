# 039 — the two import scanners disagree again, and long comments still refuse

severity: low
type: bug (residual from 018's fix), consistency
area: `_make/validate.tl`, `_make/deps.tl`

## issue

4a15b92 fixed audit 018 by patching the **validator's** scanner only:
`validate.imports_of` now strips line comments and frontier-anchors the
`require` match. two residuals:

1. **`deps.direct` still uses the old pattern.** it was not touched, so
   the two scanners disagree: a commented-out `require("x")` is now
   correctly ignored by the validator but still becomes a dependency
   edge in the compile closure — a phantom prerequisite in
   `srcdeps_*`, causing overbuilds (and a confusing edge if the
   commented module doesn't exist). the scanners agreeing was the point
   of anchoring one of them.
2. **multi-line long comments still false-positive the validator.** the
   line-comment strip (`%-%-[^\n]*`) removes the `--[[` opener's line
   only; a require on an interior line of a `--[[ … ]]` block is not
   preceded by `--` and still matches — so a commented-*block* cross-cmd
   require still refuses the project, the exact failure 018 named.
   (the mirror case — `--` inside a string literal truncating the rest
   of the line — produces false *negatives*, which the docstring already
   admits as a class.)

## where

- `_make/validate.tl` — `imports_of`, the patched scanner.
- `_make/deps.tl` (`direct`) — the unpatched one.

## suggested fix

this is the concrete argument for audit 032 (one memoized edge map): put
the one scanning function somewhere both consumers call — the pattern,
the comment handling, and any future fix land once. handling `--[[ ]]`
blocks properly wants a small state machine over `--[[`/`]]`/quotes
rather than more gsub; that is only worth writing once, in the shared
scanner.

## test to add

one table-driven test over the shared scanner: a line-commented require,
a require inside a `--[[ ]]` block, `myrequire(...)`, and a real require
after a string containing `--` — asserting the same answer from the
validator path and the deps path.
