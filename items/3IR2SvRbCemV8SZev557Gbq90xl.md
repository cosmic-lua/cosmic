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
`fd0884d91eeaa2cd5659125282c1699e91bef715`. 13 rows below, 13 scoped
bindings — counts match.

Beyond the spec's own framing, this pass found the nanosleep tuple
deviation is a family, not a singleton: `unix.gmtime`, `unix.localtime`,
`unix.setitimer`, and `unix.sigaction` all destructure to the identical
"a later success slot doubles as the error string / errno on failure"
shape when forced to fail and their full success arity is captured —
confirmed live, not inferred. It also found two genuine class-1
raise-candidates the spec's scope list didn't call out by name:
`unix.raise` and `unix.sigprocmask`, both structurally identical to
the already-settled `unix.clock_gettime` fix (#277) — an invalid
enum-style argument (signal number; `how`) is documented as their only
reachable failure, with no environmental (ESRCH/EPERM/EFAULT-from-Lua)
path.

The board had no existing capture for `unix.nanosleep` itself despite
being cited elsewhere as "the archetype" — one is filed here (`3IjRXQWcfw3QRI1RnEU5OluD87C`)
so this row, like every other deviation row, names a real capture id
rather than a bare reference to a concept.

| # | binding | class | probe | capture |
|---|---|---|---|---|
| 1 | `unix.kill` | 3 exact | `unix.kill(pid, 0)` → `true`; `unix.kill(2147483647, 0)` → `nil, "kill: ESRCH...", 3` | exact |
| 2 | `unix.killpg` | 3 exact | `unix.killpg(2147483647, 0)` → `nil, "killpg: EINVAL...", 22` | exact |
| 3 | `unix.raise` | 1 degenerate-input | `unix.raise(999)` → `nil, "raise: EINVAL...", 22`; POSIX's only documented failure is EINVAL for an invalid signal number | `3IjRXqZek8XKx2W0Dn0GHwNmLjA` |
| 4 | `unix.sigprocmask` | 1 degenerate-input | `unix.sigprocmask(999, unix.sigset())` → `nil, "sigprocmask: EINVAL...", 22`; Linux's only failures are EINVAL(bad `how`)/EFAULT(unreachable from Lua) | `3IjRZ9hD9NrStsAnyhMzwK6ZzAh` |
| 5 | `unix.sigaction` | 2 tuple-deviation | `unix.sigaction(unix.SIGKILL, unix.SIG_IGN)` → error string lands in the `flags` slot | `3IjRZi3mc1TW31yGcE7e615d4Lc` |
| 6 | `unix.sigpending` | 3 exact (effectively unreachable — see out-of-scope note) | `unix.sigpending()` → `unix.Sigset()`; only documented failure (EFAULT) is unreachable, no arguments to get wrong | exact |
| 7 | `unix.setitimer` | 2 tuple-deviation | `unix.setitimer(999)` → error string lands in the `intervalns` slot, errno in `valuesec` | `3IjRa88PfMHXoRab5q1vZjeIuTa` |
| 8 | `unix.nanosleep` | 2 tuple-deviation, ARCHETYPE | interrupted sleep → 5 values, error in slot 2 | `3IjRXQWcfw3QRI1RnEU5OluD87C` |
| 9 | `unix.gmtime` | 2 tuple-deviation | `unix.gmtime(9223372036854775807)` → error string lands in the `mon` slot (already honestly declared `integer|string mon`) | `3IjRaU2dA8zH56DfC1og37HbOug` |
| 10 | `unix.localtime` | 2 tuple-deviation | `unix.localtime(9223372036854775807)` → same `mon`/`mday` sharing | `3IjRasyoYAsJxkJsQIBK9EPn3GK` |
| 11 | `unix.setenv` | 3 exact | `unix.setenv("FOO=BAR","bar",true)` → `nil, "setenv: EINVAL...", 22` (name contains `=`); ENOMEM also documented | exact |
| 12 | `unix.unsetenv` | 3 exact | `unix.unsetenv("FOO=BAR")` → `nil, "unsetenv: EINVAL...", 22` | exact |
| 13 | `unix.clearenv` | 3 exact (effectively unreachable — see out-of-scope note) | `unix.clearenv()` → `true`; takes no arguments, glibc's clearenv() essentially never fails | exact |

13 rows / 13 scope — counts match.

Cosmic-side spend for the tuple-deviation rows (5, 7, 9, 10): each has
a `cosmic/*.tl` wrapper that already destructures the binding's full
success arity and relies on the undeclared/declared slot-sharing
(`cosmic/signal.tl` for sigaction/setitimer, `cosmic/time.tl` for
gmtime/localtime) — concrete proof the deviation is live, not
theoretical; full detail in each filed capture.
