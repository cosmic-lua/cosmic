## Goal

G3, via cosmo-contracts: `unix.nanosleep` is cited repeatedly across
this census effort as "the archetype" of a tuple-deviation class — a
later success-path slot doubles as the error string/errno on
failure — but no board item exists for the archetype itself. File one
so the family (sigaction, setitimer, gmtime, localtime — each its own
sibling capture) has a real fix to coordinate with instead of a bare
concept reference.

## Evidence

- C source: `third_party/lua/cosmo/lunix.c` — `LuaUnixNanosleep`
  (search the file for `nanosleep` at the current pin; confirm exact
  line numbers when picking this up, since they were not re-verified
  independently of the citing captures). On success it pushes the
  sleep-completion state; on an EINTR interruption it pushes the
  remaining seconds/nanoseconds AND an error indication — the citing
  captures (sigaction, setitimer, gmtime, localtime) each independently
  observed and matched this shape by destructuring nanosleep's full
  return arity.
- `tool/net/definitions.lua` — `unix.nanosleep`'s doc block declares
  slot 2 as `integer|string remnanos` (the honestly-unioned form,
  unlike sigaction/setitimer which leave the shared slot as a bare
  `integer` with no union at all).
- Probe (from the cosmopolitan repo root, against
  `make -j$(nproc) o//tool/lua/lua`) — an interrupted sleep:
  ```
  $ o//tool/lua/lua -e '
  local unix=require("unix")
  local pid=unix.fork()
  if pid==0 then
    unix.sigaction(unix.SIGALRM, function() end)
    unix.setitimer(unix.ITIMER_REAL, 0, 1)
    local ok,err,errno,rem1,rem2=unix.nanosleep(5,0)
    print(ok,err,errno,rem1,rem2)
    unix.exit(0)
  else unix.wait(pid) end'
  nil	nanosleep: EINTR: Interrupted system call	4	4	899935616
  ```
  5 return values; the error string lands in slot 2, where a
  non-interrupted call's "remaining seconds" would sit.
- cosmic-side spend: `grep -rn 'unix\.nanosleep' cosmic/` in a
  `cosmic-lua/cosmic` checkout — find and cite the wrapper site(s)
  when picking this up; the sibling captures (sigaction/setitimer/
  gmtime/localtime) each independently found their own `cosmic/*.tl`
  wrapper already coded around this exact shape.

## Change

Give `unix.nanosleep`'s failure path a return arity that never
overlaps a real success value's position — e.g. append the
EINTR-remaining-time values as genuinely separate TRAILING slots after
a clean `nil, err, errno` triple, rather than reusing the "remaining
seconds"/"remaining nanoseconds" slots for the error string/errno.
Update `definitions.lua`'s annotation to match. This is the reference
fix the sibling captures (`unix.sigaction`, `unix.setitimer`,
`unix.gmtime`, `unix.localtime`) are blocked on — land this one first,
then apply the equivalent shape to each sibling (or record a decision
that this shape is accepted as-is, in which case unblock and close the
siblings as "won't fix, documented" instead).

## Non-goals

- Does not itself fix `unix.sigaction`/`unix.setitimer`/`unix.gmtime`/
  `unix.localtime` — each is its own capture, blocked on this one so
  they land second and match whatever mechanism this item settles on.
- Does not re-litigate `unix.clock_gettime` (#277) — a different
  function, already settled, not part of this deviation family.

## Acceptance

- `unix.nanosleep`'s failure path returns a tuple where no slot serves
  two purposes across success and failure — verified by a probe
  destructuring the full return arity on both the success and the
  EINTR-interrupted path.
- `definitions.lua`'s annotation states one coherent contract.
- `make -j$(nproc) o//tool/lua/test` passes.
- The decision made here (fixed shape, or accepted exception) is
  recorded clearly enough that the four blocked sibling captures can
  proceed without re-deriving it from scratch.
