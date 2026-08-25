## Goal
G3 — an honest type layer. This item's parent is "casts: close the 55
any-map field walk from-any sites", and this is its residue: the 16
sites that share no shape with each other, spread one to four at a
time across six files.

## Evidence

Measured 2026-08-25 against `dbca9e77` with
`grep -n -- "-- cast: " <file>`. This is the census's per-file table
(`docs/design/casts.md`, the Any-map field walk section) minus the box
configuration (20), `cosmic.deep` (13) and coverage AST (6) slices:

| file | any-map sites | `from any` in file | file lines |
| --- | --- | --- | --- |
| `cosmic/format/init.tl` | 4 | 4 | 406 |
| `cosmic/fetch/init.tl` | 3 | 3 | 427 |
| `cosmic/check.tl` | 2 | 2 | 324 |
| `cosmic/fetch/headers.tl` | 2 | 2 | 47 |
| `cosmic/fs/types.tl` | 2 | 2 | 300 |
| `cosmic/sandbox/init_test.tl` | 2 | 2 | 368 |
| `cosmic/quicksand/proxy/rules.tl` | 1 | 1 | 231 |
| **total** | **16** | | |

20 + 13 + 6 + 16 = 55, the census total.

**These do not share a mechanism, which is what makes them a residue
rather than a slice.** Each is a handful of sites over a shape local to
its own module, so the closure is a record (or an `is {string: any}`
dispatch) per module, judged per module. Three of the seven files are
within 100 lines of the 500-line cap — `cosmic/fetch/init.tl` at 427,
`cosmic/format/init.tl` at 406, `cosmic/sandbox/init_test.tl` at 368 —
so a slice that adds a record declaration to one of them is a capacity
question before it is a typing question.

## Direction, not a decision

This item is a container in waiting, not a slice: 16 sites across
seven files in five unrelated subsystems is not one session's diff,
and the files are not disjoint from each other's subsystems in a way
that makes them one change.

The first refinement pass should read the seven files' sites, group
them by whether the shape is cosmic's own data (typeable) or genuinely
dynamic (`is` dispatch), and cut children along subsystem lines —
`fetch` (5 sites, two files), `format` (4), `fs` + `check` (4),
`sandbox` + `proxy` (3) is the obvious first cut but is a guess until
the sites are read. Each child states its file's measured headroom
under the 500-line cap, because that is what decides whether a record
declaration can land in the file that reads it.

Deferring this residue until the three shaped slices land is
deliberate and cheap: those three close 39 of the 55, and what they
teach about record-vs-dispatch is exactly the judgment this residue
needs.

## What this must not do

`cosmic/fetch/init.tl`, `cosmic/fetch/headers.tl`, `cosmic/check.tl`,
`cosmic/fs/types.tl` and `cosmic/format/init.tl` are all public API
whose error shapes and return contracts are frozen. `cosmic.check`
throwing is D23 and is not reopened here; `fetch`'s structured `Error`
record and its `kind` field are D24 and do not change. This work
changes how values are TYPED at their read sites, never what a
function returns or what an error says.

Each closure diff lowers the affected rows in
`_build/casts_baseline.tl` and updates the per-file table in
`docs/design/casts.md`. Run exactly the regen command the gate's
failure message prints and commit the result; no gate is weakened any
other way.
