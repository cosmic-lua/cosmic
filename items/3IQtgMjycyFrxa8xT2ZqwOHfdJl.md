## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact". Every `cosmo.*` binding
whose first `@return` admits nil is classified — degenerate-input-only
(a raise candidate), environmental (the union stays, but its tuple must
be exact), or already exact — with evidence, and each of the first two
kinds seeds a capture.

This item is now a **container**: the walk is decomposed into twelve
scoped research slices, one per row of the table below. Its own
`Acceptance` is the union of theirs, and it ends when the last child
does, after a refine that checks the union holds.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `1e165815` — the
commit carrying both settled sibling contracts, `path.join` (#276,
3IQtfuCx) and `unix.clock_gettime` (#277, 3IQtg7Sm).

The universe is one walk of `tool/net/definitions.lua`: for each
`^function` declaration, classify the FIRST `@return` line of the
contiguous `---` doc run directly above it — **NIL** when that line
contains `|nil` or its type token ends in `?`, **EXACT** otherwise,
**NONE** when the run declares no `@return`. As `census.awk`, run from
the cosmopolitan repo root:

```awk
/^---/ { run[n++] = $0; next }
/^function / {
  name = $2; sub(/\(.*/, "", name)
  cls = "NONE"
  for (i = 0; i < n; i++) {
    if (run[i] ~ /^---@return /) {
      split(run[i], f, " ")
      cls = (index(run[i], "|nil") > 0 || f[2] ~ /\?$/) ? "NIL" : "EXACT"
      break
    }
  }
  print cls "\t" name
  n = 0; next
}
{ n = 0 }
```

```text
$ awk -f census.awk tool/net/definitions.lua | cut -f1 | sort | uniq -c
    209 EXACT
    192 NIL
     38 NONE
$ grep -c '^function ' tool/net/definitions.lua
439
```

209 + 192 + 38 = 439, so the walk classifies every declaration and
drops nothing. **192 nil-admitting bindings is the workload**, not the
439 functions or the 510 `@return` lines the first spec quoted —
neither of those bounds what the `Change` asked for.

**This supersedes the per-module figures in the bounce note below.**
That walk reported `unix` 128 (it predates #277), `lsqlite3` 30, and
"`cov` and `repl` declare 2 bindings between them". Re-derived here:
`unix` 127, `lsqlite3` 22 NIL of 108 declarations, and `cov`/`repl`
declare 7 between them, all EXACT. Re-run the command above rather than
either note's numbers.

## The decomposition

`unix`'s 127 are cut by family. The eight families partition that 127
exactly — no binding in two, none left out — checked with `comm` over
the sorted walk output and the sorted family lists. Each child carries
its own scope list verbatim, plus the classes, the evidence standard
and the capture rule, so none of them needs to read this item.

| child | scope | rows |
|---|---|---|
| 3IR2Pzsv | unix filesystem namespace operations | 22 |
| 3IR2RMdN | unix stat, directory streams and temp fds | 11 |
| 3IR2RYCJ | unix descriptor and terminal I/O | 17 |
| 3IR2RpK9 | unix sockets and network | 21 |
| 3IR2SFOq | unix ids, credentials and sessions | 15 |
| 3IR2SQaC | unix process, exec and scheduling | 12 |
| 3IR2SiiK | unix sandboxing, namespaces and limits | 16 |
| 3IR2SvRb | unix signals, time and environment | 13 |
| 3IR2TE1O | lsqlite3 | 22 |
| 3IR2TQdU | the top-level `cosmo` surface | 22 |
| 3IR2TpB3 | zip | 14 |
| 3IR2U42t | re, getopt and argon2 | 7 |

127 + 22 + 22 + 14 + 7 = 192, the walk's NIL total.

Sizing: the bounce priced the evidence standard at four artifacts per
row and a session at roughly a dozen rows, so no child exceeds 22 and
the median is 15. `path` (7 bindings, all exact since #276) and
`cov`/`repl` (7 bindings, all exact) contribute no rows and get no
child.

## Two findings already in hand

Summary rows the children inherit rather than re-derive:

- **`path` is exact, entirely.** All 7 of `join`, `basename`,
  `dirname`, `exists`, `isfile`, `isdir`, `islink` have a non-nil first
  `@return`. `join` was the last, closed by 3IQtfuCx (#276).
- **`cov` and `repl` are exact**, in all 7 of their declarations.

The two known-degenerate bindings the original Evidence named are both
settled: `path.join` by #276 and `unix.clock_gettime` by #277, which is
why neither appears in the 192.

## Non-goals

- No code change in either repo — this container and its children
  produce captures and evidence only.
- No scope past the modules the coverage test's `MODULES` list names
  (`tool/lua/test_definitions_coverage.lua`). The `fetch`/`lfetch`
  surfaces belong to their own board thread.
- No promotion of the filed captures, and none of the children — the
  order is the goal owner's `compare`.

## Acceptance

- Every child above has ended, each having recorded its own summary
  table and filed its class-1 and class-2-deviation captures.
- The union check: the children's row counts sum to 192, and
  re-running `census.awk` at that time yields no nil-admitting binding
  that appears in no child's table.
- `gitboard tree` under this item lists the twelve children and the
  captures they seeded.

## Enablement

none needed. Each child is workable from its own spec. The children
write no repo files, so they are parallel-safe with each other and with
any contract slice they seed.

## Bounce record, 2026-08-26

Pulled and bounced without a PR at `5fb988db`. Nothing about the METHOD
was found wanting — the three classes, the evidence standard and the
capture rule are all carried into the children unchanged. What broke
was the size: the spec sized itself on counts (439 functions, 510
`@return` lines) that do not bound the walk its `Change` asked for, and
never measured the one that does. The countermeasure is the measured
table above with the command that produced it, and the decomposition it
justifies — this item's own specification failure, not a new enablement
item.
