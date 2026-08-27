# The flow review

Where the WIP limits come from. `_work/flow.tl`'s `LIMITS` table holds
one number per phase, and each of those numbers is a measured one:
this file is the record of what it was measured against, the reasoning
that set it, and the condition under which it is measured again. A
flow review rewrites this file; the rules module carries the numbers
and a pointer here.

The instrument is this branch's own git log over `items/*.tl`. Every
board mutation is exactly one commit with a structured subject, so the
log IS the flow record and nothing separate can fall behind it:
pairing successive commits for one id gives that item's stints, the
paired timestamps give each stint's dwell, and one ordered walk
tracking a running per-phase set of open ids gives peak concurrent
occupancy. `gitboard stats` prints the dwells and the transition
counts from that same parse; peak occupancy comes from the walk.

## Measured 2026-08-23

Over the board branch's history to that date: 162 items, 91 ended, 326
transitions.

| phase | dwell median | peak | limit measured against | at or over |
| ----- | -----------: | ---: | ---------------------: | ---------- |
| plan  |        3h39m |   49 |                     12 | near-continuous |
| ready |          18m |   12 |                     12 | 2% |
| do    |           6m |    3 |                      5 | 0 |
| check |        2h38m |    6 |                     10 | 0 |
| land  |          55s |    4 |            3, now none | 11% |

`plan` is the second confirmation its own tripwire asked for. It held
49 against a limit of 12 at a 42 h median age, because no rung ever
consulted that number: adoption from triage entered `plan` ungated, so
the limit throttled only decomposition — the deliberate intake — while
the reactive channel ran unbounded. Draining triage WAS filling plan,
at 13.5 attaches a day against 9 refinements out. So `plan` is now
what its name claims: a small committed queue fed by an explicit
`promote`, with the unbounded `backlog` absorbing what triage places.
`ready` is cut with it rather than alone, as that tripwire required.

`land` is unbounded. Its dwell median of 55 seconds is a step, not a
state, and it is the rightmost phase: a limit there throttles arrivals
into the last thing an item does, which is finishing. The peak of 4
against a limit of 3 is what that cost — a number that binds and is
then forced through.

`do` and `check` are unchanged — their peaks never came near their
numbers, so they stay unjudged rather than confirmed.

## Tripwires

Each names the condition that makes its phase worth measuring again.

- **plan** — `promote` is refused twice in one session with `ready`
  not full: the committed queue binding against refinement capacity
  rather than against inventory.
- **ready** — revisit with plan; refinement fills it, so the two move
  together or the buffer starves the phase behind it.
- **do** — peak reaches 5 with a MIX of claims: that is concurrent
  sessions, where all-other-sessions is the stalled-claim state
  `action.next_action` reports.
- **check** — peak reaches 10 with a mix of claims; all from ONE
  session is the handover stall, not a limit signal.

## The blocked-inventory rule (2026-08-27)

Not a limit change — an ordering one, recorded here because it
changes what a limit MEANS when a phase fills with blocked items.

The starvation rule ("every ready item is blocked → name the chain
root before anything upstream") used to outrank the whole intake
half. Measured against the 2026-08-27 sessions, that fired twice on
wall-clock blockers (a release cron, an upstream merge) with `ready`
at 2/5: the loop stalled on an unresolvable `unblock` while three
free slots and refinable `plan` items stood idle. The rule
over-approximated "the column is clogged" from "every current member
is blocked".

Now the blocked members only OCCUPY their slots: intake keeps
refining and promoting past them while the limit has room, and the
starvation answer fires in exactly two places — when it binds
(`ready` at its limit with every member blocked, so no refinement
can feed a pullable item) and as the fallback when intake has
nothing left. Both name the chain root; neither leaves a silent
stall. The same principle skips a blocked `do` item in the finish
rung: it cannot be finished, holds its slot for the limit, and the
pull proceeds while room remains.

Tripwire: `ready` sitting AT its limit with every member blocked for
longer than a session — that is the moment blocked inventory is
consuming the whole buffer, and the flow review should ask whether
those items belong in `ready` at all or back in `plan` behind their
blockers.
