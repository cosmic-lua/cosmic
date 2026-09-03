## Evidence

Found by the builder of item `3Int8VXj9GcPOKsNsQtTiP5t8cl` (the
`cosmic.sqlite.Blob` wrapper, blocked on a `3p/cosmos` pin bump)
while trying to consume cosmopolitan PR #372's new
`value_type`/`column_type` accessors.

Bumping `3p/cosmos/cosmos_pin.tl` from the currently-pinned
`2026.08.31-6dfa6728a` to the release carrying #372
(`2026.09.03-903f9e59a`) — a jump of 75 cosmopolitan commits — breaks
a COLD `bin/cosmic --make build` on the current `main`, independent
of any sqlite-specific change: verified by stashing all sqlite-side
edits and rebuilding from a clean `o/` with only the pin bump
applied, and the failure reproduced identically.

The 75-commit range (cosmopolitan PRs #308-#362) is a systematic
binding-contract-shape rewrite: several `cosmo.unix`/`cosmo.re`
bindings moved from multi-value returns to single named-table
returns. Confirmed unadapted call sites across cosmic's own tree,
each failing to type-check against the new shapes:

- `_cli/main_handlers.tl` — `unix.mkstemp`'s new `MkstempPath` table
- `cosmic/fd.tl` — `unix.pipe`'s new `Pipe` table
- `cosmic/re.tl`, `cosmic/re_test.tl` — `re.Regex:find`/`:search`'s
  new `SearchMatch`/`Match` tables
- `cosmic/signal.tl` — `unix.setitimer`'s new `Itimerval`,
  `unix.sigaction`'s new `SignalAction`, and `Sigset`
- `cosmic/time.tl` — `unix.localtime`/`gmtime`'s new
  `BrokenDownTime`, and `SleepRemainder`
- `cosmic/tty.tl` — likely affected by the same family, unconfirmed
  in detail

`bin/cosmic --make ci` never gets far enough to run past the cold
build failure, so the true extent of what's broken (whether this
list is complete, whether any of these are load-bearing enough to
break other modules transitively) is not yet fully mapped — the
builder stopped at reproducing and characterizing the blocker, not
exhaustively cataloging every call site.

This is a general project-level gap, not specific to sqlite or to
`3Int8VXj`: ANY board item whose build needs a `3p/cosmos` pin past
`6dfa6728a` is blocked the same way, and the gap will only widen as
more cosmopolitan PRs land ahead of cosmic's next adaptation pass.

## Change

An adaptation pass: for each of cosmopolitan PRs #308-#362's
binding-contract-shape changes (multi-value return → named-table
return), update cosmic's corresponding call site(s) to the new
shape, then bump `3p/cosmos/cosmos_pin.tl` to a release carrying all
of them, and confirm a COLD `bin/cosmic --make ci` passes (not just
an incremental build against pre-existing `o/` state, which will not
catch a broken cold build the way this item's own reproduction
required stashing changes and rebuilding from clean `o/`).

Concretely:

1. Enumerate every binding-contract-shape change in cosmopolitan
   between the current pin (`6dfa6728a`) and the target
   (`903f9e59a` or later, at the refiner's discretion) — the PR
   range #308-#362 is the known lower bound from this item's
   reproduction, re-verify it's complete against cosmopolitan's own
   PR history in that range, since "further pin bumps needed" only
   grows this range.
2. For each, update the cosmic-side call site(s) — the list above is
   a confirmed start, not exhaustive; a cold build failure after
   fixing the known list means there are more.
3. Bump the pin once every call site type-checks against the new
   shapes.
4. Confirm `bin/cosmic --make ci` passes cold (clean `o/`, matching
   this repo's own cold-build-rule doctrine in AGENTS.md).

## Non-goals

- No new cosmic features riding along with the adaptation — this is
  purely absorbing already-landed cosmopolitan contract changes.
- Not itself building `3Int8VXj`'s `cosmic.sqlite.Blob` wrapper —
  that item's own sqlite-side implementation is already drafted
  (uncommitted, in its own worktree) and just needs this pin bump to
  verify against; it stays blocked on this item, not folded into it.
