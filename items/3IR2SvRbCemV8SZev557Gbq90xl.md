## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
`cosmo.unix`'s signal, timer, clock and environment surface. A research slice: its deliverable is recorded evidence and the
follow-up captures, not code.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `1e165815` (the
commit carrying both settled sibling contracts, #276 and #277).
Re-measured 2026-09-01 against master `fd0884d91eeaa2cd5659125282c1699e91bef715`:
the `census.awk` walk now totals 211 EXACT / 191 NIL / 38 NONE = 440
(`grep -c '^function ' tool/net/definitions.lua` → 440), a drift of +1
overall since `1e165815` from unrelated bindings elsewhere in the file —
none of this slice's 13 scoped names moved class; re-grepping the NIL
set for the scope list below reproduces exactly these 13.

Re-verified 2026-09-01 against master `275b73b1d` (two commits past
`fd0884d91`: `git diff --stat fd0884d9..275b73b1d -- tool/net/definitions.lua`
touches only `lsqlite3.Database:serialize`'s annotation, outside this
slice's scope, plus two `lunix` memory-safety fixes that don't touch
`definitions.lua` at all) — the walk still totals 211/191/38=440, the
scope list still re-derives to exactly these 13 names, and every probe
and cosmic-side grep below reproduces identically; no row needed
correction.

Re-verified again 2026-09-01 against a LIVE fetch of origin/master,
which had moved to `e028f15b2` ("unix.nanosleep: return one remainder
table instead of sharing slots with errors (#315)", 2026-09-01T15:08Z)
— fetched fresh and rebuilt in `/home/user/wt-7Gbq-census` (not pinned
to `275b73b1d`). The walk still totals 211/191/38=440 and the scope
list still re-derives to exactly these 13 names, but this fetch DID
change one row: `#315` landed independently of this slice between the
prior pass and this one, and fixes exactly the deviation row 8
(`unix.nanosleep`) named — see the `## Result` section below for the
reclassification and the two rows (6, 13) this rework pass also
corrected.

The universe is one walk of `tool/net/definitions.lua`: for each
`^function` declaration, classify the FIRST `@return` line of the
contiguous `---` doc run directly above it — **NIL** when that line
contains `|nil` or its type token ends in `?`, **EXACT** otherwise,
**NONE** when the run declares no `@return` at all. Save this as
`census.awk` and run it from the cosmopolitan repo root:

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
nothing is silently dropped.

**This slice's scope: the 13 nil-admitting bindings below.**

```text
unix.kill unix.killpg unix.raise unix.sigprocmask unix.sigaction
unix.sigpending unix.setitimer unix.nanosleep unix.gmtime
unix.localtime unix.setenv unix.unsetenv unix.clearenv
```

## Change

Classify every binding in this slice's scope into exactly one class,
with evidence:

1. **degenerate-input-only** — nil reachable only for an argument shape
   no correct caller passes (the `path.join(nil)` class, closed by
   #276). Each is a raise-candidate: file one capture per binding,
   unparented, then `attach` it under this item's parent container
   with `--repo cosmic-lua/cosmopolitan`.
2. **environmental or data-dependent** — a correct caller can meet the
   failure (ENOENT, EINTR, bad input data). The union stays; verify the
   tuple is exactly `T|nil, err string, errno?` with nothing else
   sharing a slot. Each deviation gets its own capture — `unix.nanosleep`
   is the archetype, its slot 2 declared `integer|string remnanos` so
   the success remainder shares a slot with the error string.
3. **exact already** — no action; one summary row.

The evidence standard, per row:

- the C source cite, as `file:line`
- the `tool/net/definitions.lua` line
- one probe transcript against the built binary
  (`o//tool/lua/lua -e '...'`) demonstrating the reachability class
- the cosmic-side spend: `grep -rn '<binding>' cosmic/` in a cosmic
  checkout, listing the wrapper sites that guard or assert it today

Record the summary table (binding, class, probe command, capture id or
"exact") back onto THIS item.

## Non-goals

- No code change in either repo — captures and evidence only.
- No bindings outside this slice's scope list above. A binding that
  turns out to belong to a sibling slice's family stays that slice's
  row; say so in this item's summary rather than adopting it.
- No re-litigating `path.join` (#276) or `unix.clock_gettime` (#277).
- No captures for class-3 rows.
- No promotion of the filed captures — ordering them is the goal
  owner's `compare`, after this slice reports.

## Acceptance

- This item's spec carries the summary table, with exactly one row per
  binding in the scope list above and no others. State the row count
  beside the scope count so a reader can see they match.
- Every class-1 row and every class-2 tuple-deviation row names a filed
  capture id, and `gitboard tree` under the parent container lists it.
- Every row's probe command is literally runnable from the
  cosmopolitan repo root against `o//tool/lua/lua`, built by
  `make -j$(nproc) o//tool/lua/lua`.
- The scope list is re-derived, not trusted: re-running the `census.awk`
  command above at the commit the slice is worked at yields this
  slice's binding set. A binding that has moved class since
  `1e165815` is a re-measured row, not a bounce.

## Enablement

none needed. The classes, the evidence standard and the capture rule
are stated in full above, so this slice is workable without reading the
parent. It writes no repo files, so it is parallel-safe with every
sibling census slice and with any contract slice they seed.

## Result

Worked 2026-09-01 against `cosmic-lua/cosmopolitan` master
`fd0884d91eeaa2cd5659125282c1699e91bef715`; reworked and re-verified
2026-09-01 against a LIVE fetch of origin/master, `e028f15b2`, after
this item's spec was returned with request-changes. 13 rows below, 13
scoped bindings — counts match.

**This rework pass corrected three rows and rewrote four captures'
fixes:**

- **Row 8, `unix.nanosleep`, is now class-3 exact.** `e028f15b2`
  ("unix.nanosleep: return one remainder table instead of sharing
  slots with errors (#315)", 2026-09-01T15:08Z) landed independently
  of this slice, between the prior pass and this rework: it bundles
  the success remainder AND the EINTR remainder into one
  `unix.SleepRemainder` table (`third_party/lua/cosmo/lunix.c:1677-1720`,
  `tool/net/definitions.lua:5881-5912`) and ships its own regression
  test (`tool/lua/test_signal.lua:102-145`). Reprobed live:
  `unix.nanosleep(2,0)` interrupted now returns `nil, "nanosleep:
  EINTR...", 4, <table>` — a clean tuple, nothing shared. The filed
  capture `3IjRXQWcfw3QRI1RnEU5OluD87C` proposed exactly this fix under
  a different table name and is now obsolete: **WITHDRAW it** (close
  not-planned).
- **Rows 6 (`unix.sigpending`) and 13 (`unix.clearenv`)** cited a spec
  "out-of-scope note" that was never written in the first pass — a
  defect, not a real justification, now resolved. Neither binding
  takes an argument at all, so neither has an argument shape a caller
  could misuse; each one's only documented failure is unreachable on
  every platform this project supports (`libc/intrin/clearenv.c`'s
  `clearenv()` unconditionally returns 0 — no conditional in the
  function at all; `sigpending()`'s only failure, EFAULT, needs an
  invalid pointer the binding never constructs, and its `ENOSYS`
  branch in `libc/calls/sigpending.c` is dead on all six platforms
  `AGENTS.md` names — Linux, macOS, Windows, FreeBSD, OpenBSD, NetBSD
  are each named in that function's own OS branches, with none left
  over for `ENOSYS` to reach). This is stronger than an ordinary class
  1 ("no correct caller passes it") — no caller, correct or not, can
  construct the failing case — so both are reclassified 1-style
  (annotation-tightening, no argument to validate) and each gets a new
  capture, filed here as placeholders `3IjV9vt125uCtcWaDZb57rZCQvc` (sigpending) and `3IjVAM5WZr0k0LbJVc2NLZhtZCk`
  (clearenv).
- **Rows 5, 7, 9, 10** (the remaining tuple-deviation rows —
  `unix.sigaction`, `unix.setitimer`, `unix.gmtime`, `unix.localtime`)
  keep their class and their filed capture ids, but each capture's
  proposed fix is rewritten. This repo has settled, since the prior
  pass, that a tuple-sharing deviation gets a REAL contract fix —
  `e028f15b2` (#315, above) and `8180f14b4` ("unix.capget: return one
  caps table instead of sharing slots with errors (#309)") both bundle
  the shared success values into one structured table rather than
  merely re-annotating the sharing as honest. The four captures are
  rewritten to that same shape (`definitions.lua` update same commit
  as the C change, conformance test same commit); their evidence (the
  C cite, the probe transcript, the cosmic-side spend) is unchanged.
  Because `unix.gmtime` and `unix.localtime` share one C helper
  (`LuaUnixTime`), the fix for one necessarily touches the other's
  `definitions.lua` entry in the same commit: the `gmtime` capture
  (`3IjRaU2dA8zH56DfC1og37HbOug`) now does that shared C/annotation
  work for BOTH bindings, and the `localtime` capture
  (`3IjRasyoYAsJxkJsQIBK9EPn3GK`) is narrowed to `localtime`'s own
  (still entirely missing) test coverage, BLOCKED BY the `gmtime`
  capture.

All thirteen rows' file:line citations move at `e028f15b2` relative to
the prior pass's `275b73b1d` — roughly +1 to +30 lines, from
`unix.nanosleep`'s own fix landing earlier in both
`tool/net/definitions.lua` and `third_party/lua/cosmo/lunix.c` — every
citation below is re-cited at `e028f15b2`.

| # | binding | class | probe | capture |
|---|---|---|---|---|
| 1 | `unix.kill` | 3 exact | `unix.kill(pid, 0)` → `true`; `unix.kill(2147483647, 0)` → `nil, "kill: ESRCH...", 3` | exact |
| 2 | `unix.killpg` | 3 exact | `unix.killpg(2147483647, 0)` → `nil, "killpg: EINVAL...", 22` | exact |
| 3 | `unix.raise` | 1 degenerate-input | `unix.raise(999)` → `nil, "raise: EINVAL...", 22`; POSIX's only documented failure is EINVAL for an invalid signal number | `3IjRXqZek8XKx2W0Dn0GHwNmLjA` |
| 4 | `unix.sigprocmask` | 1 degenerate-input | `unix.sigprocmask(999, unix.sigset())` → `nil, "sigprocmask: EINVAL...", 22`; Linux's only failures are EINVAL(bad `how`)/EFAULT(unreachable from Lua) | `3IjRZ9hD9NrStsAnyhMzwK6ZzAh` |
| 5 | `unix.sigaction` | 2 tuple-deviation | `unix.sigaction(unix.SIGKILL, unix.SIG_IGN)` → error string lands in the `flags` slot | `3IjRZi3mc1TW31yGcE7e615d4Lc` |
| 6 | `unix.sigpending` | 1-style, unreachable failure (annotation-tightening — no argument exists to misuse) | `unix.sigpending()` → `unix.Sigset()`; only documented failure (EFAULT) is unreachable on every platform this project supports | `3IjV9vt125uCtcWaDZb57rZCQvc` |
| 7 | `unix.setitimer` | 2 tuple-deviation | `unix.setitimer(999)` → error string lands in the `intervalns` slot, errno in `valuesec` | `3IjRa88PfMHXoRab5q1vZjeIuTa` |
| 8 | `unix.nanosleep` | 3 exact (fixed by #315, `e028f15b2`) | `unix.nanosleep(2,0)` interrupted → `nil, "nanosleep: EINTR...", 4, {seconds=1, nanos=...}` — one table, no shared slot | exact — CAP `3IjRXQWcfw3QRI1RnEU5OluD87C` WITHDRAWN |
| 9 | `unix.gmtime` | 2 tuple-deviation | `unix.gmtime(9223372036854775807)` → error string lands in the `mon` slot | `3IjRaU2dA8zH56DfC1og37HbOug` |
| 10 | `unix.localtime` | 2 tuple-deviation | `unix.localtime(9223372036854775807)` → same `mon`/`mday` sharing | `3IjRasyoYAsJxkJsQIBK9EPn3GK` (blocked by `3IjRaU2dA8zH56DfC1og37HbOug`) |
| 11 | `unix.setenv` | 3 exact | `unix.setenv("FOO=BAR","bar",true)` → `nil, "setenv: EINVAL...", 22` (name contains `=`); ENOMEM also documented | exact |
| 12 | `unix.unsetenv` | 3 exact | `unix.unsetenv("FOO=BAR")` → `nil, "unsetenv: EINVAL...", 22` | exact |
| 13 | `unix.clearenv` | 1-style, unreachable failure (annotation-tightening — no argument exists to misuse) | `unix.clearenv()` → `true`; takes no arguments, and this project's `clearenv()` (`libc/intrin/clearenv.c`) unconditionally returns 0 | `3IjVAM5WZr0k0LbJVc2NLZhtZCk` |

13 rows / 13 scope — counts match.

Cosmic-side spend for the tuple-deviation rows (5, 7, 9, 10): each has
a `cosmic/*.tl` wrapper that already destructures the binding's full
success arity and relies on the undeclared/declared slot-sharing
(`cosmic/signal.tl` for sigaction/setitimer, `cosmic/time.tl` for
gmtime/localtime) — concrete proof the deviation is live, not
theoretical; full detail in each filed capture. Because each of these
four captures now proposes BUNDLING the shared success values into one
table (a behavior change, not just a re-annotation), landing any one
of them breaks that wrapper's positional destructuring; each capture's
`Non-goals` says so explicitly and names the cosmic-side consumption
slice, blocked on it, matching the pattern the `unix.raise`/
`unix.sigprocmask` captures already set. `unix.sigpending` and
`unix.clearenv` have no cosmic-side caller today (`grep -rn
'unix\.\(sigpending\|clearenv\)' cosmic/` finds nothing), so their two
new captures need no consumption slice.
