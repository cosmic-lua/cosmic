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

## Status

The 16-file worktree the previous attempt left at
`/tmp/claude-0/-home-user/15925051-9a03-506a-af49-a6b214eeb796/scratchpad/worktrees/A3HK_gamw`
is gone (`ls` → `No such file or directory`; `.git/worktrees` holds only
`board`; no branch, stash or dangling object matches). The surviving
record is the list below; redo from it. Blocked on `generate-seed-types`
(a cold build otherwise checks generator closures against the trust
root's bundled types — see `3IoULYAu`'s Recommendation).

Pin gap, measured: `3p/cosmos/cosmos_pin.tl` = `2026.08.31-6dfa6728a`;
`git log --oneline 6dfa6728a..origin/master | wc -l` → 76 (PRs
#298-#373); newest release `2026.09.03-833e4353f`. Target that release.

## Call-site map (refreshed)

Every line verified with `git grep -n 'unix\.(…)' origin/main -- 'cosmic/**' '_cli/**'`
at `96afd807`; tests/examples beside each file follow the same edit.
Old → new shape, cosmopolitan PR, cosmic sites:

- `unix.wait`: `pid, wstatus, rusage` → `WaitResult{pid,wstatus,rusage}`
  (`nil, err, errno` on failure) #340 — proc/init.tl:252,
  child/init.tl:161, child/io.tl:132,134, quicksand/box/run.tl:343,
  quicksand/init.tl:136, quicksand/proc.tl:284,291,
  quicksand/proxy.tl:75,84,95,169,174, quicksand/proxy/serve.tl:383
- `unix.pipe`: `reader, writer` → `Pipe{reader,writer}` #328 — fd.tl:247,
  child/init.tl:243, quicksand/box/run.tl:309, quicksand/init.tl:115,
  quicksand/proc.tl:178, quicksand/proxy.tl:117
- `unix.getrlimit`: `soft, hard` → `Rlimit{soft,hard}` #324 —
  proc/rusage.tl:41; `unix.raise`/`sigprocmask` raise on a bad argument
  instead of `nil, err` #324 — signal.tl:181, 267
- `unix.setitimer`: four ints → `Itimerval` #331 — signal.tl:201;
  `unix.sigaction`: `handler, flags, mask` → `SignalAction` #338 —
  signal.tl:252, child/io.tl:30,32 (restores the previous disposition:
  read `.handler`), quicksand/proc.tl:276
- `unix.getpgrp`: bare integer #336 — proc/init.tl:46 (drop the
  `assert:`-justified assert; the type no longer admits nil)
- `unix.gmtime`/`localtime`: 11 values → `BrokenDownTime` #321 —
  time.tl:128, 158; `sigpending`/`clearenv` tightened #321 and `capget`
  → `Caps` #309 — no cosmic site (`git grep 'unix\.(sigpending|clearenv|capget)'` → none)
- `unix.mkstemp`: `fd, path` → `fd, {path=…}` #329 — fs/ops.tl:381,
  fs/file.tl:94, embed/init.tl:375, _cli/main_handlers.tl:93
- `unix.nanosleep`: five ints → `SleepRemainder|nil, err, errno,
  SleepRemainder?` #315 — time.tl:83 (quicksand/proxy.tl:81 discards)
- `unix.Dir:read` failure now `nil, err, errno` #326 — fs/dir.tl:27,
  doc/query.tl:61, embed/init.tl:111, _cli/build/steps.tl:97
- `unix.getsockopt` SO_LINGER returns two values #332 — net/socket.tl:406
  (wrapper's declared return); `openpty`/`isatty`/`tiocgwinsz`
  annotation-only #311/#307/#335 — tty.tl:82, 113, 121 (recheck narrowing)
- `re.Regex:find` → `re.Match{start,stop,captures}` #318 — re.tl:280,
  326; `:match`/`:search`/`re.search` → `re.SearchMatch|nil, string?`
  #319 — re.tl:188 (the assert at re.tl:199 goes with it)
- `getopt.parse` raises on argument-shape errors #317 — flags/getopt.tl:91
- `lsqlite3.open` failure `nil, errmsg, code` (slots swapped) #316 —
  sqlite/init.tl:415, 417; `prepare` slot 2 is a message #322 —
  sqlite/init.tl:272, sqlite/stmt_cache.tl:63, 116; `config`/
  `wal_checkpoint` #320/#334 — no cosmic site
- New surface, no site to adapt: `create_function` deterministic flag
  #337 (`3If5tfhK`), `extensions()`/`register_extension` #364,
  `column_type`/`value_type` #372 (`3Int8VXj`); session API removed #373
  (`git grep -n 'changeset\|session' origin/main -- 'cosmic/sqlite/**'` → none)

Then bump `3p/cosmos/cosmos_pin.tl` to `2026.09.03-833e4353f` (sha from
the release's `SHA256SUMS`) and prove with `rm -rf o && bin/cosmic --make ci`
ending `ci: PASS`.
