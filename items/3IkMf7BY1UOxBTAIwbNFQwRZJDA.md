## Goal

Bring cosmic onto a cosmos release carrying the exact-contract work
landed upstream after the current pin, so the items that consume one of
those contracts (`unix.nanosleep`'s remainder table, `cosmo.cov.budget`)
can each be a small wrapper change instead of a hidden pin bump that
breaks every other wrapper at once.

## Evidence

The pin (`3p/cosmos/cosmos_pin.tl`) is `2026.08.31-6dfa6728a`. Measured
from a cosmopolitan checkout at `origin/master` = `0f64e8e6`:

```
$ git log --oneline 6dfa6728a..origin/master | wc -l
40
$ git tag --sort=-creatordate | head -1
2026.09.01-97f4b4e16
```

Contract changes in that window, each a frozen-boundary change the
pinned types will re-render (upstream PR in parentheses):

- `unix.nanosleep` returns one remainder table (#315)
- `unix.pipe` returns one `unix.Pipe` table (#328)
- `unix.mkstemp` returns a path table (#329)
- `unix.getrlimit` bundles its pair (#324); `unix.raise` / `unix.sigprocmask`
  raise on argument-shape errors (#324)
- `unix.gmtime` / `unix.localtime` return one `BrokenDownTime` table;
  `sigpending` / `clearenv` nils tightened (#321)
- `unix.setitimer` bundles previous-value fields into one table (#331)
- `unix.capget` returns one caps table (#309)
- `unix.getsockopt` SO_LINGER arity (#332); `unix.Dir` readdir failure vs
  end-of-directory (#326); `unix.isatty` (#307) and `unix.openpty` (#311)
  declared shapes
- `re.Regex:find` returns one `re.Match` table (#318); `re.Regex:search`
  / `:match` / `re.search` bundle match+captures (#319)
- `getopt.parse` raises on argument-shape errors (#317)
- `lsqlite3.open` / `open_memory` failure slot order (#316); `config`
  (#320), `Database:prepare` (#322), `wal_checkpoint` (#334) return
  string errors instead of bare codes
- `cosmo.cov.budget`, a new binding (#304)

Cosmic call sites of those bindings outside tests, measured with
`grep -rnoE '<the binding names>' --include=*.tl cosmic/ _cli/ _make/ _tool/ _perf/ _fuzz/ | grep -v _test.tl`:

```
cosmic/sqlite/init.tl (3), cosmic/sqlite/stmt_cache.tl (2),
cosmic/sqlite/defaults.tl, cosmic/sqlite/init_example.tl,
cosmic/flags/getopt.tl (2), cosmic/flags/parse.tl,
cosmic/tty.tl (openpty, isatty), cosmic/time.tl (nanosleep, gmtime, localtime),
cosmic/signal.tl (sigprocmask, setitimer, raise),
cosmic/quicksand/proxy.tl (pipe, nanosleep), cosmic/quicksand/proc.tl,
cosmic/quicksand/init.tl, cosmic/quicksand/box/run.tl (pipe),
cosmic/proc/rusage.tl (getrlimit), cosmic/net/socket.tl (getsockopt),
cosmic/fs/ops.tl, cosmic/fs/file.tl, cosmic/embed/init.tl,
_cli/main_handlers.tl (mkstemp), cosmic/fd.tl, cosmic/child/init.tl (pipe),
_perf/bench/re_bench.tl (re.match)
```

Two todo items already assume the bump happens inside their own PR —
`1iOZ_4iqj` (time.tl for nanosleep, #315) and `qPiX_DdxS` (fuzz budget,
#304) — and both would carry every wrapper fix above as a side effect.
Neither spec names that cost. They are blocked on this item.

## Change

One PR on cosmic-lua/cosmic:

1. `3p/cosmos/cosmos_pin.tl`: bump `version` to `2026.09.01-97f4b4e16`
   (or the newest release at pull time — re-run `git tag` above) and
   `sha` to that release's `cosmos.zip` sha256. Then, per AGENTS.md's
   update procedure: `bin/cosmic --make fetch`, `bin/cosmic --make build`,
   `o/bin/cosmic --make ci`.
2. For every wrapper the regenerated types break, change ONLY the
   wrapper's internal destructuring of the `cosmo.*` call to the new
   shape. Each wrapper's own public contract (its Teal signature and its
   documented error behaviour) is unchanged; if a wrapper's contract
   cannot be preserved under the new binding shape, stop and file that
   wrapper as its own item blocked on nothing, then continue with the
   rest.
3. Run the compare gate against the previous pin per the `optimize`
   skill (`_perf/run.tl` before and after, `_perf/gate.tl compare`), as
   AGENTS.md requires for a cosmos pin bump.

## Non-goals

- No consumption of the NEW capabilities the release carries
  (`cosmo.cov.budget`, `nanosleep`'s EINTR remainder for
  `sleep_remaining_ms`): those are `1iOZ_4iqj` and `qPiX_DdxS`, which this
  item unblocks.
- No wrapper contract changes; no `cosmo.*` direct use added anywhere
  outside `cosmic/`.
