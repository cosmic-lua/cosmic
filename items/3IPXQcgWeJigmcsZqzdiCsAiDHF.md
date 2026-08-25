## Goal

G3 — an honest type layer, and the "types never lie" promise at its
sharpest. `docs/design/nil-flow.md`'s census found one site in the
PUBLISHED API where the type does not merely fail to prove a value is
non-nil — it asserts something the binding underneath does not support:

```
-- cosmic/time.tl:32
--- @return integer Seconds since epoch
--- @return integer Nanoseconds
local function now(): integer, integer
  local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
  return secs, nanos
end
```

`unix.clock_gettime` returns `integer | nil` in slot 1. `now()` declares
`integer, integer`. A clock failure is therefore a nil handed to a caller
whose type says it cannot receive one — and every caller of
`cosmic.time.now()` inherits that lie. `monotonic`, `now_ms`,
`monotonic_ms` and `monotonic_ns` repeat the shape; the census flags
seven rows in the file (`:35`, `:44`, `:53`, `:61`, `:71` and the two
return slots), re-derived 2026-08-25.

## The shape, decided

**The module asserts the read and throws if it ever fails.** The three
candidates the census left open, and why this is the one:

1. **Fallible return** (`now(): integer | nil, string`) — rejected on
   count. `grep -rn --include='*.tl' -E '\btime\.(now|monotonic)(_ms|_ns)?\('`
   finds **43 call sites** outside `o/`, most of them timing loops and
   log timestamps. Pushing an unreachable nil onto all 43 is the failure
   the Non-goals below name: it moves the lie one level out and buys no
   caller a decision they can act on.
2. **Throw** — chosen. `clock_gettime`'s `integer | nil` is honest for an
   arbitrary caller-supplied clock id (EINVAL on an unsupported one) and
   unreachable for the two CONSTANTS this module passes,
   `unix.CLOCK_REALTIME` and `unix.CLOCK_MONOTONIC`. `assert` is the
   Lua primitive for exactly that claim, and the carried
   `narrow-assert-decl` patch makes `local secs = assert(...)` yield a
   plain `integer`, so the fix is one line per site with no cast.
3. **Document and guard without throwing** — rejected as incoherent:
   there is no honest value to return in place of the time. A `or 0`
   fallback replaces a type lie with a data lie, silently.

**This slice cannot land until D23 admits it** (blocker 3IQZalzf).
D23 closes the exemption list — "No other `cosmic.*` module may throw or
exit" — so the throw has to be licensed by an amended record, not by
this diff.

## Change

In `cosmic/time.tl`, at every `unix.clock_gettime` call, bind through
`assert` with a message naming the clock, so the local is a plain
`integer` and the declared returns stop lying:

```
local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
->
local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
local s = assert(secs, "clock_gettime(CLOCK_REALTIME) failed")
```

(or the equivalent single-expression form where only one slot is used).
The five functions are `now`, `monotonic`, `now_ms`, `monotonic_ms` and
`monotonic_ns`. Their signatures do NOT change — that is the point of
the shape chosen.

Add a doc comment at the first call recording the invariant: the union
belongs to the binding's general contract, the constants passed here
cannot produce it, and the assert is what makes that claim checkable
rather than assumed. Then give the module's other `unix.*` call sites
the same treatment in the same diff — a module is consistent within
itself — and update AGENTS.md's throw rule per whatever 3IQZalzf
decided.

## Non-goals

- **Do not widen the return type by reflex.** `integer | nil` with no
  decision about what a caller does with the nil moves the lie one level
  out; that is the failure mode this slice exists to avoid.
- **Do not touch `whilp/cosmopolitan`.** `clock_gettime`'s C contract is
  frozen and correct: the union is right for an arbitrary clock id, and
  the defect is this side's, in passing a constant and then declaring
  the result infallible without saying so.
- **Do not fix other census sites.** `_build/size.tl` and
  `cosmic/fs/tree.tl` are separate work.
- **Do not change `cosmic.time`'s public function names or units.** D20
  governs; this slice changes honesty, not naming.
- **Do not amend D23 here.** That is the blocker, and a doctrine change
  landing inside the diff it licenses proves nothing.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/time_test.tl` ends `test: PASS`, with a
  new test pinning that the assert message names the clock — the failure
  path is unreachable through the public API, so the test covers the
  message shape, not a forced failure.
- Re-running the census's Method (`docs/design/nil-flow.md`, `## Method`)
  reports `cosmic/time.tl` absent from the flagged files (today 7 rows).
- All 43 call sites compile unchanged: no caller appears in the diff.

## Enablement

The doctrine seat is blocker 3IQZalzf (amend D23), filed rather than
settled here. Nothing else: `narrow-assert-decl` already makes `assert`
narrow in expression position, and AGENTS.md's error-handling block is
where the resulting rule is written down.
