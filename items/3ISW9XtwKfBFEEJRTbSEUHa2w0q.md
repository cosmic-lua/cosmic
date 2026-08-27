## Goal

G3 (this item's parent root) — decision records state their licence as
granted: D30's justification grammar names one exit spelling where the
licence (a process boundary with no caller) covers any exit call, and
the enforcement lint already reads both.

## Change

In `docs/decisions/d30-throw-exit-boundaries.md`, correct the grammar
sentence in the decision section — today (measured 2026-08-27,
`grep -n 'on an .os.exit' docs/decisions/d30-throw-exit-boundaries.md`
→ line 52):

> `-- exits: <why>` on an `os.exit(` line

becomes

> `-- exits: <why>` on an exit call's line (`os.exit(`, `unix.exit(`)

Per the decide skill this is a **correct** (a detail the tree outgrew;
no claim changes): edit in place, no status change, no amendment
bullet. Evidence the tree outgrew it: six post-fork children exit via
`unix.exit(` and all carry `-- exits:` markers — measured 2026-08-27,
`grep -rn "unix.exit(" cosmic/quicksand | grep -v _test` →
`cosmic/quicksand/proxy.tl:135,152,159,161`,
`cosmic/quicksand/proxy/serve.tl:404`, `cosmic/quicksand/init.tl:127`
— and the enforcement lint (PR #1412) reads the receiver, covering
both spellings.

## Non-goals

No amendment bullet, no `status` change, no retitle (the correct
class). Line 9's census wording (`error(` and `os.exit(`) is context —
a snapshot per the decide skill, not maintained. AGENTS.md is
untouched: its D30 doctrine bullet names no exit spelling (verified
2026-08-27, `grep -n "os.exit" AGENTS.md` hits only the narrowing
paragraph at line 181, a different subject). No lint change: the lint
already covers both spellings.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "unix.exit" docs/decisions/d30-throw-exit-boundaries.md`
  returns 1 (today: 0).
- `grep -rn "on an .os.exit" docs/decisions/` returns nothing
  (today: d30 line 52).

## Enablement

none needed — a one-line prose correction; the decide skill's correct
class is the licence.
