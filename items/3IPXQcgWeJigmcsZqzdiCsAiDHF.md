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

`unix.clock_gettime` returns `integer | nil` in both slots. `now()`
declares `integer, integer`. A clock failure is therefore a nil handed
to a caller whose type says it cannot receive one — and every caller of
`cosmic.time.now()` inherits that lie. `cosmic/time.tl:44` repeats the
shape and `:53` multiplies one of the values.

## Change

Decide what `cosmic.time` does when the clock call fails, then make the
signature say it. The census does not choose for you; the three
candidates, and what each costs:

1. **Fallible return** — `now(): integer, integer` becomes
   `now(): integer | nil, string`, or the pair rides a record. Honest,
   and it breaks every caller. Enumerate them first
   (`grep -rn "time\.now\|time\.monotonic" --include='*.tl'`) — the
   count decides whether this is one slice or several.
2. **Throw** — `CLOCK_REALTIME` failing is not a recoverable condition,
   so treat it like the CSPRNG's throw-on-failure, which AGENTS.md
   already names as one of exactly two exemptions from "never throw
   from library code". Cheapest for callers; needs its exemption written
   into AGENTS.md beside the CSPRNG's, and a decision record if the
   exemption list is meant to be closed.
3. **Document the invariant and guard** — if `clock_gettime` on
   `CLOCK_REALTIME` cannot fail on any platform cosmic ships to, say so
   at the site with the evidence, and guard anyway so the types match.

Read `cosmic/time.tl:30-60` and the three sites the census names
(`:35`, `:44`, `:53`) before choosing. Whichever lands, the other
`unix.*` call sites in that file get the same treatment in the same
diff — a module is consistent within itself.

## Non-goals

- **Do not widen the return type by reflex.** `integer | nil` with no
  decision about what a caller does with the nil moves the lie one
  level out; that is the failure mode this slice exists to avoid.
- **Do not touch `whilp/cosmopolitan`.** `clock_gettime`'s C contract
  is frozen and correct; the defect is on this side.
- **Do not fix other census sites.** `_build/size.tl` and
  `cosmic/fs/tree.tl` are separate work.
- **Do not change `cosmic.time`'s public function names or units.**
  D20 governs; this slice changes honesty, not naming.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/time_test.tl` ends `test: PASS`, with
  a new test covering the failure path the chosen shape introduces.
- Re-running the census's Method reports `cosmic/time.tl` absent from
  the flagged files (today 7 sites).
- Every caller enumerated in `Change` 1 compiles unchanged, or is
  updated in this diff and named in the PR.

## Enablement

none needed. The three shapes are AGENTS.md's own error-handling
doctrine; the exemption precedent for shape 2 is
`docs/decisions/d23-check-throws.md` and the CSPRNG's throw. If shape 2
is chosen and the exemption list is meant to be closed, that is a
decision record and the `decide` skill is how it is written — file it
as a blocker rather than settling it inside this diff.
