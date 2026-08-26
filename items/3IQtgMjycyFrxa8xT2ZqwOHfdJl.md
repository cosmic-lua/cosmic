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

## Bounced 2026-08-26 — the slice is ~15x a session, on a number the
## spec never measured

Pulled and bounced without a PR at whilp/cosmopolitan `5fb988db`
(master carrying the merged sibling #276). Nothing about the METHOD was
found wanting — the three classes, the evidence standard and the
capture rule are all right. What breaks is the size, and the missing
measurement is the one that decides it.

**The universe the Evidence never counted.** The spec sizes itself on
"439 functions … 507 `@return` lines carry `|nil` or `?`", but the
`Change` scopes the walk to bindings whose **FIRST** `@return` admits
nil. That count is not in the spec, and it is the whole workload.
Measured at `5fb988db` by walking each `function` block's first
`@return` (an awk pass over `git show
origin/master:tool/net/definitions.lua`; a `@return` line matches when
it contains `|nil` or its type ends in `?`):

```text
201 bindings whose first @return admits nil
200 whose first @return is exact
 38 with no @return at all
```

Per module, over that 201 (`grep '^NIL' | awk '{print $2}' |
sed 's/[:.].*//' | sort | uniq -c | sort -rn`):

| module | nil-admitting | note |
|---|---|---|
| `unix` | 128 | 46 of the 201 overall are `:` methods |
| `lsqlite3` | 30 | |
| `cosmo` | 22 | |
| `zip` | 14 | |
| `re` | 5 | |
| `getopt` | 1 | |
| `argon2` | 1 | |
| `path` | 0 | closed by #276 — see below |
| `cov`, `repl` | 0 | 2 bindings total, both exact |

**Why that breaks the shape.** The evidence standard is four artifacts
per row — a C `file:line`, a definitions line, a probe transcript run
against `o//tool/lua/lua`, and a `grep -rn` of the cosmic-side spend.
201 rows is roughly 800 artifacts, and `Acceptance` additionally
requires a filed capture for **every** class-1 and class-2-deviation
row. Even at a conservative one-in-four, that is dozens of new items
against a triage queue whose limit is 8 — so the slice as written
would either flood the board or be quietly truncated, and a census
that silently stops is worse than none. `decompose.md`'s smell
threshold is a diff a session can hold in its head; this is ~15x a
session's worth of walking.

**Proposed decomposition** (the goal owner's to order, not this
session's to place): one slice per module, each self-contained because
the classes, the evidence standard and the capture rule are already
written above and can be copied verbatim into each child.

- `unix` (128) needs cutting further on its own — one slice per family
  (fd/file, process, socket, time, signal, ids) rather than one slice
  of 128. Sizing that cut is the first refinement job.
- `lsqlite3` (30), `cosmo` (22), `zip` (14) are each plausibly one
  session.
- `re` (5), `getopt` (1), `argon2` (1), `cov`/`repl` (0) collapse into
  a single tail slice of 7 rows.

Each child keeps this item's `## Change`, `## Non-goals` and evidence
standard unchanged, with the scope line naming its module and the
count above as its measured universe. This item then becomes the
container they hang under, and its own `Acceptance` becomes the union
of theirs.

**Two findings already in hand, free of the walk.** Both are summary
rows the decomposition should carry rather than re-derive:

- **`path` is now exact, entirely.** All 7 of its bindings — `join`,
  `basename`, `dirname`, `exists`, `isfile`, `isdir`, `islink` — have
  a non-nil first `@return` at `5fb988db`. `join` was the last one,
  and the sibling slice 3IQtfuCx (#276, merged) closed it. The module
  needs no census slice at all.
- **`cov` and `repl` declare 2 bindings between them, both exact.**
  They are inside the `Change`'s scope list but contribute no rows.

The two known-degenerate bindings the Evidence names are also both
settled now: `path.join` by #276, and `clock_gettime` by 3IQtg7Sm
(#277, green and in review at the time of this bounce), which is why
neither appears in the 201 above when measured against a master
carrying them.

## Enablement

none needed. Parallel-safe with the two sibling contract slices —
this slice writes no repo files, so no ordering constraint exists.

The bounce above is this item's own specification failure: the
`Evidence` asserted two counts (`439 functions`, `507 @return lines`)
that do not bound the work the `Change` asks for, and never measured
the one that does. The countermeasure is the measured table above,
with the command that produced it, carried into whatever children this
becomes — not a new enablement item.
