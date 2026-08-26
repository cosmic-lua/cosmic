## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact". A research slice: its
deliverable is recorded evidence and the follow-up slices, not code.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `3c36bc35`:
`tool/net/definitions.lua` is 8276 lines declaring 439 functions
(`grep -c "^function" tool/net/definitions.lua`), of which 510
`@return` lines carry `|nil` or `?`
(`grep -c -E '^---@return [^ ]*(\|nil|\?)' tool/net/definitions.lua`).
Two of those unions are already known degenerate-input-only
(`path.join`, `clock_gettime` — the sibling slices); one tuple-shape
deviation is already known (`nanosleep`'s slot 2 declared
`integer|string remnanos`, sharing the success remainder with the
error string, lines 5866–5869). Nobody has walked the rest.

## Change

Classify every binding whose FIRST `@return` admits nil, scoped to the
modules cosmic wraps — the MODULES list of
`tool/lua/test_definitions_coverage.lua`: cosmo, unix, path, re,
argon2, lsqlite3, getopt, zip, cov, repl.

For each, assign one class with evidence:

1. **degenerate-input-only** — nil reachable only for an argument
   shape no correct caller passes (the `path.join(nil)` class). Each
   is a raise-candidate: file one capture per binding, attached under
   this item's parent container, `--repo whilp/cosmopolitan`.
2. **environmental or data-dependent** — a correct caller can meet the
   failure (ENOENT, EINTR, bad input data). The union stays; verify
   the tuple is exactly `T|nil, err string, errno?` with nothing else
   sharing a slot. Each deviation (nanosleep's is the archetype) gets
   its own capture.
3. **exact already** — no action; one summary row.

The evidence standard per capture, and per summary row: the C source
cite (`file:line`), the definitions cite (`line`), one probe transcript
against the built binary (`o//tool/lua/lua -e '...'`) demonstrating the
reachability class, and the cosmic-side spend
(`grep -rn '<binding>' cosmic/` in a cosmic checkout, listing the
wrapper sites that guard or assert it today).

Record the summary table (binding, class, probe command, capture id or
"exact") back onto THIS item with `gitboard spec`, then finish per
review.md's research-slice clause — the deliverable is the board
state, no product PR.

## Non-goals

- No code change in either repo — captures and evidence only.
- No re-litigating the two settled siblings; their rows cite the
  sibling ids.
- No captures for class-3 rows, and no scope creep past the coverage
  test's MODULES list (fetch/lfetch surfaces belong to their own
  board thread).
- No promotion of the filed captures — ordering them is the goal
  owner's compare, after this slice reports.

## Acceptance

- This item's spec carries the summary table, and its row set is
  complete over the scope: every scoped `function` block whose first
  `@return` matches `-E '^---@return [^ ]*(\|nil|\?)'` appears exactly
  once (the two greps above bound the universe; state the scoped count
  the walk found beside the command that found it).
- Every class-1 and class-2-deviation row names a filed capture id;
  `gitboard tree` under the parent container lists them.
- Every row's probe command is literally runnable from the
  cosmopolitan repo root against `o//tool/lua/lua`.

## Enablement

none needed. Blocked by nothing; parallel-safe with the two sibling
contract slices (this slice writes no repo files).
