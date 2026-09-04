## Goal

Bring cosmic onto a cosmos release carrying the exact-contract work
landed upstream after the current pin, so the items that consume one of
those contracts (`unix.nanosleep`'s remainder table, `cosmo.cov.budget`,
FTS5, `register_extension`) can each be a small wrapper change instead
of a hidden pin bump that breaks every other wrapper at once.

**Un-narrowed 2026-09-04.** The 2026-09-01 narrowing (drop the eight
generator-closure wrappers, leave them on the old shape) is withdrawn:
`3IkSSqvH4BLD8YdvdYwohk2Pemz`'s Resolution measured that NO shape of
those files cold-builds under the current trust root, and that under a
trust root carrying D43's seed pass (#1656) they are ordinary one-PR
adaptations. This item is therefore the WHOLE adaptation again, one PR,
and it waits on exactly one thing: `bin/cosmic.pin` naming a release
that contains `8758f80c` — item `3Ip8zrCbHnPiV5bRM49XvoxXNCM`
(«Xvox_XNCM»), this item's blocker. Do not pull it before that lands;
do not try the narrowing again.

## Evidence

Measured 2026-09-04 against `origin/main` `79aa8c16`, in a detached
worktree, cosmos pin bumped from `2026.08.31-6dfa6728a` to
`2026.09.04-65bc139fc` (the newest release; sha256 of the downloaded
`cosmos.zip`: `9f3cb4bada574951f04bd46e79933e087d3594c1c94ee35d77ca7102d6488886`,
matching the release's `SHA256SUMS` row). Re-verify the newest release
at pickup time exactly as before: list releases, download
`cosmos.zip`, `sha256sum` it, compare with `SHA256SUMS` — a prior
version of this spec named a version that was stale within hours.

**The affected set, measured the only valid way.** The pinned engine's
own `gentype` renders the new annotations differently from the tree's
(a cold build under `2026-08-31-a5b36f4` reported 6 failing files; the
tree's renderer reports 23), so the set below was produced by
generating the declarations with the tree's own binary and checking
every non-test source against them:

```
$ o/bin/cosmic _types/types_gen.tl /tmp/newtypes        # tree binary, new pin fetched
$ git ls-files 'cosmic/*.tl' '_cli/*.tl' '_make/*.tl' '_tool/*.tl' '_perf/*.tl' '_fuzz/*.tl' \
    '_types/*.tl' '_build/*.tl' '_docs/*.tl' 'cmd/*.tl' | grep -v '_test\.tl$\|\.d\.tl$' \
  | xargs o/bin/cosmic --check types --include-dir /tmp/newtypes 2>&1 \
  | grep 'error:' | cut -d: -f1 | sort | uniq -c
      4 _cli/main_handlers.tl          unix.mkstemp   slot 2 is MkstempPath | string (#329, #374)
      6 cosmic/child/init.tl           unix.wait → WaitResult (#340); unix.pipe → Pipe (#328)
      3 cosmic/child/io.tl             unix.wait; unix.sigaction → SignalAction (#338)
     10 cosmic/embed/init.tl           unix.mkstemp
      1 cosmic/fd.tl                   unix.pipe
      1 cosmic/fs/dir.tl               unix.Dir:read slot 2 is integer | string (#326, #374)
     10 cosmic/fs/file.tl              unix.mkstemp
      1 cosmic/fs/ops.tl               unix.mkstemp
      1 cosmic/flags/getopt.tl         getopt.parse raises on shape errors (#317)
      3 cosmic/proc/init.tl            unix.wait
      2 cosmic/proc/rusage.tl          unix.getrlimit → Rlimit
      9 cosmic/quicksand/box/run.tl    unix.pipe, unix.wait
      6 cosmic/quicksand/init.tl       unix.pipe
      9 cosmic/quicksand/proc.tl       unix.pipe, unix.wait
     14 cosmic/quicksand/proxy.tl      unix.pipe, unix.wait
      1 cosmic/quicksand/proxy/serve.tl unix.wait
      8 cosmic/re.tl                   re.Regex:find → Match; :search/:match/re.search → SearchMatch (#318, #319)
      8 cosmic/signal.tl               unix.sigaction, unix.setitimer → Itimerval (#331), unix.raise/sigprocmask (#324)
      4 cosmic/sqlite/init.tl          lsqlite3.open/open_memory failure slot order (#316); wal_checkpoint (#334, #374)
     21 cosmic/time.tl                 unix.nanosleep → SleepRemainder (#315); gmtime/localtime → BrokenDownTime
      3 cosmic/tty.tl                  unix.openpty (#311); unix.tiocgwinsz (#335)
```

(`cosmic/fd.tl` and `cosmic/fs/dir.tl` show 1 each because the
measurement worktree had already adapted them to prove the seed path;
the pristine tree reports `fd.tl:253` and `dir.tl:28` — same sites.)
Tests that fail the same check: `cosmic/re_test.tl` (15),
`cosmic/quicksand/box/run_test.tl` (2), `cosmic/child/io_test.tl` (1).
`_perf/bench/re_bench.tl`, `cosmic/net/socket.tl` (`getsockopt`) and
`cosmic/sqlite/{stmt_cache,defaults}.tl` pass unchanged.

A type-check pass under the OLD trust root is not evidence of
adaptation: it accepted `child/init.tl:165`'s `wpid == 0` against a
`WaitResult` — code that would never reap a child at runtime. Every
`unix.wait`/`unix.pipe` caller above is a behaviour change, not only a
type change; `cosmic/child/init_test.tl` and the quicksand tests are
the proof they still work.

Upstream window: the binding PRs named per row above (from the
2026-09-01 version of this spec, #311–#331) plus the `definitions.lua`
commits between the two releases —
`git log 6dfa6728a..65bc139fc -- tool/net/definitions.lua` in a FULL
cosmopolitan clone (a shallow clone's ancestry answers are wrong):
#333–#338, #340, #342, #356, #364, #370–#372, #374, #377, #382. Two of
those are not shape changes but matter to the same wrappers: #372
(lsqlite3 distinguishes BLOB from TEXT at the value boundary — a
runtime behaviour change `cosmic/sqlite/*_test.tl` must still pass
under) and #377 (fallible `@overload` arms now render `true|nil`
tuples — new `| nil` slots may appear on bindings not in the table;
the build's own type check finds them).

Two todo items already assume this pin bump: `1iOZ_4iqj` (time.tl for
nanosleep, #315) and `qPiX_DdxS` (fuzz budget, #304); `3ImjB20O`
(FTS5, needs ≥ `d88e994fc`) and `3In3fTdC` (`register_extension`,
needs ≥ `405d8840d`) are satisfied by any release at or after
`2026.09.02-405d8840d` — the newest is — and are blocked on this item.

## Change

One PR on cosmic-lua/cosmic, pulled only after «Xvox_XNCM» is on main
(`git show origin/main:bin/cosmic.pin | grep url` names a release
whose tag commit contains `8758f80c`):

1. `3p/cosmos/cosmos_pin.tl`: bump `version` and `sha` to the newest
   cosmos release at pickup time, at or after `2026.09.04-65bc139fc`
   (re-verify per Evidence). Then, per AGENTS.md's update procedure:
   `bin/cosmic --make fetch`, `bin/cosmic --make build`,
   `o/bin/cosmic --make ci`. Generation 1 now seeds the declarations
   from this pin (D43), so the closure compile fails on the FIRST
   unadapted closure member with the real error — adapt and re-run.
2. For every file the regenerated types break (the table above is the
   expected set; the build is the authority), change ONLY the
   wrapper's internal destructuring of the `cosmo.*` call to the new
   shape. Each wrapper's own public contract — its Teal signature and
   its documented error behaviour — is unchanged. Where slot 2 is now
   a union (`MkstempPath | string`, `integer | string`), narrow with
   `is` on the success branch; no casts. If a wrapper's contract
   cannot be preserved under the new binding shape, stop and file that
   wrapper as its own item, unparented, with the site quoted, then
   continue with the rest.
3. Run the compare gate against the previous pin per the `optimize`
   skill (`_perf/run.tl` before and after, `_perf/gate.tl compare`),
   as AGENTS.md requires for a cosmos pin bump.

Sizing: ~23 files, ~130 diagnostics, most of them one- or two-line
destructuring edits. It is over the ~400-line smell threshold and is
still one PR: a pin bump is atomic — the tree compiles against exactly
one `definitions.lua` — so there is no file-disjoint split that leaves
each half green.

## Non-goals

- No consumption of the NEW capabilities the release carries
  (`cosmo.cov.budget`, `nanosleep`'s EINTR remainder for
  `sleep_remaining_ms`, FTS5 search, `register_extension`): those are
  `1iOZ_4iqj`, `qPiX_DdxS`, «So6c_e5pY» via `3ImjB20O`, and
  «bnpp_lZOK» via `3In3fTdC`.
- No wrapper contract changes; no `cosmo.*` direct use added anywhere
  outside `cosmic/`.
- No `bin/cosmic.pin` change here — that is «Xvox_XNCM», landed first.

## Acceptance

- `3p/cosmos/cosmos_pin.tl` carries the newest cosmos release verified
  at pickup time.
- A COLD build passes: `rm -rf o && bin/cosmic --make fetch &&
  bin/cosmic --make ci` ends `ci: PASS` (the `build` and `repro` lanes
  run exactly this).
- The perf compare gate (`_perf/gate.tl compare`) against the previous
  pin shows no unexplained regression.
