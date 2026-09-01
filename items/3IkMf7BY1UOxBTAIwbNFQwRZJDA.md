## Goal

Bring cosmic onto a cosmos release carrying the exact-contract work
landed upstream after the current pin, so the items that consume one of
those contracts (`unix.nanosleep`'s remainder table, `cosmo.cov.budget`)
can each be a small wrapper change instead of a hidden pin bump that
breaks every other wrapper at once.

**Narrowed 2026-09-01**: the original spec named every wrapper the
upstream window's contract changes touch. A builder attempt found that
a subset of those wrappers cannot compile under ANY single source text
today — `cosmic/fd.tl`, `cosmic/fs/ops.tl`, `cosmic/fs/file.tl`,
`cosmic/embed/init.tl`, `cosmic/child/init.tl`,
`cosmic/proc/rusage.tl`, `cosmic/time.tl`, and `_cli/main_handlers.tl`
are all transitively required during the build's own generation phase
(via `cosmic.fs`/`cosmic.child`/`cosmic.proc`, or loaded on every cold
invocation), so they compile under `bin/cosmic.pin`'s stale embedded
types during generation and under the tree's fresh post-bump types
during the later compile-batch step — no single destructuring
satisfies both. This is now its own capture,
`3IkSSqvH4BLD8YdvdYwohk2Pemz`, needing a real decision (stage behind a
`bin/cosmic.pin` bump, or decouple the generation-phase dependency)
before those specific wrappers can be fixed. This item is narrowed to
drop them; picking this item back up on the OTHER wrappers, listed
below, is unaffected by that hazard — confirmed by the same builder
attempt via `o/bootstrap/cosmic --check types`.

## Evidence

The pin (`3p/cosmos/cosmos_pin.tl`) was `2026.08.31-6dfa6728a`. Verify
the newest cosmic-lua/cosmopolitan release fresh at pickup time — a
prior version of this spec named `2026.09.01-97f4b4e16`, which was
already stale by the time a builder checked; `2026.09.01-0f64e8e6c`
was the newest at that check. Re-derive: `git tag --sort=-creatordate`
in a fresh cosmopolitan clone, or list releases via the GitHub API, and
independently compute the `cosmos.zip` sha256 against the release's
own `SHA256SUMS` — do not trust either this spec's or a prior
attempt's stated version/sha blindly.

Contract changes in the upstream window, each a frozen-boundary change
the pinned types will re-render (upstream PR in parentheses) —
**scoped to the wrappers THIS item still covers**:

- `unix.gmtime` shape and comment updates fall under the excluded
  `cosmic/time.tl` (see Narrowed note) — NOT in this item's scope.
- `re.Regex:find` returns one `re.Match` table (#318); `re.Regex:search`
  / `:match` / `re.search` bundle match+captures (#319) —
  `cosmic/re.tl`, `cosmic/re_test.tl`, `_perf/bench/re_bench.tl`.
- `unix.raise` / `unix.sigprocmask` raise on argument-shape errors
  (#324); `unix.setitimer` bundles previous-value fields (#331) —
  `cosmic/signal.tl`.
- `unix.openpty` declared shape corrected (#311) — `cosmic/tty.tl`
  (`isatty`, #307, needs no change).
- `getopt.parse` raises on argument-shape errors (#317) —
  `cosmic/flags/getopt.tl` (`cosmic/flags/parse.tl` needs no change).
- `lsqlite3.open`/`open_memory` failure slot order (#316) —
  `cosmic/sqlite/init.tl` (`stmt_cache.tl`, `defaults.tl`,
  `init_example.tl` route prepare-errors through `raw_db:errmsg()` and
  need no change for #322/#334).
- `unix.pipe` returns one `unix.Pipe` table (#328) —
  `cosmic/quicksand/proxy.tl`, `cosmic/quicksand/init.tl`,
  `cosmic/quicksand/box/run.tl` (NOT `cosmic/fd.tl` or
  `cosmic/child/init.tl` — those are the excluded, generation-reachable
  set).
- `cosmic/net/socket.tl` (`getsockopt`) — verify at pickup time whether
  any change is needed; a prior attempt found none (the generic 3-tuple
  shape is unchanged; #332's SO_LINGER-arity fix doesn't affect this
  wrapper, which never special-cased SO_LINGER).

Cosmic call sites, in-scope files only, measured with
`grep -rnoE '<binding names>' --include=*.tl cosmic/ _cli/ _make/ _tool/ _perf/ _fuzz/ | grep -v _test.tl`
at pickup time (re-run rather than trust this list — the tree moves):
`cosmic/re.tl`, `cosmic/signal.tl`, `cosmic/tty.tl`,
`cosmic/flags/getopt.tl`, `cosmic/sqlite/init.tl`,
`cosmic/quicksand/proxy.tl`, `cosmic/quicksand/init.tl`,
`cosmic/quicksand/box/run.tl`, `cosmic/net/socket.tl`,
`_perf/bench/re_bench.tl`.

Two todo items already assume a pin bump happens inside their own PR
— `1iOZ_4iqj` (time.tl for nanosleep, #315) and `qPiX_DdxS` (fuzz
budget, #304) — both of which touch the EXCLUDED, generation-reachable
set (`cosmic/time.tl`) or a module not addressed here; they stay
blocked until `3IkSSqvH4BLD8YdvdYwohk2Pemz`'s decision lands.

## Change

One PR on cosmic-lua/cosmic:

1. `3p/cosmos/cosmos_pin.tl`: bump `version` and `sha` to the newest
   cosmos release at pickup time (re-verify per Evidence above). Then,
   per AGENTS.md's update procedure: `bin/cosmic --make fetch`,
   `bin/cosmic --make build`, `o/bin/cosmic --make ci`.
2. For every wrapper THIS item's Evidence lists (the non-excluded set)
   that the regenerated types break, change ONLY the wrapper's internal
   destructuring of the `cosmo.*` call to the new shape. Each wrapper's
   own public contract (its Teal signature and its documented error
   behaviour) is unchanged. If a wrapper's contract cannot be preserved
   under the new binding shape, stop and file that wrapper as its own
   item blocked on nothing, then continue with the rest.
3. Do NOT touch `cosmic/fd.tl`, `cosmic/fs/ops.tl`, `cosmic/fs/file.tl`,
   `cosmic/embed/init.tl`, `cosmic/child/init.tl`,
   `cosmic/proc/rusage.tl`, `cosmic/time.tl`, or
   `_cli/main_handlers.tl` — these stay on the OLD destructuring
   (correct against the OLD pin, and the only shape that lets the
   build's generation phase compile under `bin/cosmic.pin` today) until
   `3IkSSqvH4BLD8YdvdYwohk2Pemz` resolves. If the pin bump alone (with
   no destructuring changes anywhere) fails to reach a green `--make ci`
   because one of these excluded files' generation-phase compile
   already breaks even under the OLD destructuring, STOP — that would
   mean the hazard is broader than currently scoped, and is itself new
   evidence for `3IkSSqvH4BLD8YdvdYwohk2Pemz`, not something to
   improvise around here.
4. Run the compare gate against the previous pin per the `optimize`
   skill (`_perf/run.tl` before and after, `_perf/gate.tl compare`), as
   AGENTS.md requires for a cosmos pin bump.

## Non-goals

- No consumption of the NEW capabilities the release carries
  (`cosmo.cov.budget`, `nanosleep`'s EINTR remainder for
  `sleep_remaining_ms`): those are `1iOZ_4iqj` and `qPiX_DdxS`, both
  still blocked pending `3IkSSqvH4BLD8YdvdYwohk2Pemz`.
- No wrapper contract changes; no `cosmo.*` direct use added anywhere
  outside `cosmic/`.
- No fix to any of the generation-reachable wrappers listed in
  `## Change` step 3 — that is `3IkSSqvH4BLD8YdvdYwohk2Pemz`'s decision
  to unblock, then its own follow-up item(s).

## Acceptance

- `3p/cosmos/cosmos_pin.tl` carries the newest cosmos release verified
  at pickup time.
- `o/bin/cosmic --make ci` ends `ci: PASS` with ONLY the in-scope
  wrappers' destructuring changed — `git diff --name-only` against the
  prior commit shows no touch to any file step 3 excludes.
- The perf compare gate (`_perf/gate.tl compare`) against the previous
  pin shows no unexplained regression.
