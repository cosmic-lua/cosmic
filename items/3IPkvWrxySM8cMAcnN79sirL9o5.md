## Goal

G3 — an honest type layer. 30 of the 358 census sites are optional
record fields read without the copy-to-a-local guard AGENTS.md already
prescribes. They are the existing doctrine going unapplied, so they
close with no design decision — and once closed, the doctrine sentence
that names them has a clean record of being followed.

## Evidence

`docs/design/nil-flow.md`'s producer table attributes 30 sites to field
declarations rather than function returns:
`cosmic/format/init.tl:22` (7), `cosmic/_teal_engine.tl:50` (5),
`_perf/peers/peers.tl:28` (4), `_tool/example.tl:21` and `:30` (5),
`_tool/benchmark.tl:29` and `:38` (5), `_make/types.tl:133` (2),
`_build/size.tl:44` (2).

AGENTS.md states the rule and the limitation in one clause: "What still
does NOT narrow: record FIELDS (copy the field to a local and guard the
local)."

The unions are honest — the field really may be absent — so the fix is
never to widen or narrow the record. It is to read the field into a
local and guard it, which the checker does credit.

## Change

For each of the 30 sites, copy the field into a local at the point of
use and guard the local, or restructure the branch so the field is read
once behind an existing guard. Where a field is genuinely always set by
the time it is read, say why in a comment beside the guard — do not
delete the guard and do not add a cast.

Where a record is filled in two phases (`_perf/peers/peers.tl:28`
`build_argv: {string} | nil -- compiled in setup when set`), consider
whether the two phases want two record types instead of one nilable
field, and decide it in this slice rather than deferring.

## Non-goals

- Do not add a cast or a `-- cast:` line at any of these sites.
- Do not change a record's field types to make the checker quiet.
- Do not touch the checker or `3p/tl/tl_patch.tl`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- Re-deriving the census shows zero sites attributed to the nine field
  declarations listed above.
- `git diff origin/main...HEAD | grep -c '^+.*-- cast:'` is `0`.
