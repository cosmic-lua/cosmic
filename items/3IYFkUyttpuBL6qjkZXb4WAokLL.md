## Goal

G8 — the flow system. A WIP limit exists to cap work IN PROGRESS. A
blocked item is not in progress: nobody can refine it to the ready bar
until its blocker clears, and it leaves its phase by someone else's
work, not by its holder's. It still consumes a slot, and the phase
starves.

## Problem

Observed live across three consecutive `/work` passes, 2026-08-28
15:5x–16:13. The board did not change between them and `next` returned
the same answer each time:

```
plan    4/4
  3IYCkSTY  …tiebreak…                    @0b13d2b4   (claimed, live)
  3IVEEDO8  …meta.timestamp…              [blocked]
  3IWx3I4Z  …unread A/A control…          [blocked]
  3IPXRRd2  strict nil-flow mode          [blocked]
ready   1/5
  3IWU4i0l  …two samples, no A/A control… [blocked]
do      0/5
gitboard-status: WIP: plan 4/4 at limit — arrivals refused; ready starved
gitboard-next: intake — every open root has live work — …
```

Three of `plan`'s four slots hold items no session can advance. The
fourth is legitimately claimed. `plan` therefore refuses every arrival
while exactly ONE item in it is being planned, `ready` is 1/5 and its
one item is blocked too, `do` is empty, and `backlog` holds 184. The
loop falls through every higher-priority action to `intake` — the
lowest — and reports `intake` three passes running, because no
promotion can land and nothing in `plan` can move right.

`status` names the symptom in its own words (`ready starved`) without
connecting it to the cause.

### The principle is already settled — this is its third instance

`3I1VnwDm` (#1248, completed) established it for untriaged captures,
quoting the doc comment the machinery then carried:

> Whether an issue occupies a WIP-limit slot in a phase: false exactly
> for an epic sitting in plan, true otherwise. An epic is a container
> that lives in plan until every child closes — **not work in progress
> — and counting it against the limit starves the phase.**

Both of those exemptions have since become STRUCTURAL rather than
conditional, which is why the predicate is gone: a container is
de-phased the moment a child attaches, and a capture is unparented so
it holds no phase at all. Neither can occupy a slot any more.

A blocked item is the same shape and is the one case that did NOT
become structural. It is a parented leaf, it holds a phase, and it
counts:

```
grep -n 'LIMITS\|local limit = \|#(b\[phase\]' _work/flow.tl
  55:  local LIMITS: {string: integer} = {   -- plan 4, ready 5, do 5, check 10
 176:    local n = #(b[phase] or {})
 180:    local limit = LIMITS[phase]
grep -rn 'counts_against_limit' _work/*.tl
  (no matches — the predicate no longer exists)
```

`wip_violations` takes a raw depth. The machinery already knows what
blocked means — the function immediately below `wip_violations` decides
"whether one recorded blocker edge still holds its item up", and
`status` uses it to print the `[blocked]` marks and the `flow:` line
above. The fact is computed and rendered; the occupancy count ignores
it.

## Change

Decide which of two readings is right, then implement it. **Do not
assume the first** — the second is a real position and the evidence
above does not settle it.

1. **A blocked item does not count against its phase's limit.** The
   direct analogue of the epic and capture exemptions: restore a
   `counts_against_limit`-shaped predicate over the blocked test that
   `status` already calls, and report the exempt count the way the old
   `(+%d epics)` rendering did, so a reader sees `plan 1/4 (+3
   blocked)` and not a bare `4/4`.

2. **A blocked item does not belong in `plan` at all.** If it cannot be
   refined, holding it there is inventory, and the honest move is to
   return it to `backlog` when it blocks and re-promote when the
   blocker clears. This keeps the limit meaning exactly what it says
   and needs no exemption vocabulary — but it churns phase history and
   loses the "committed to" signal `plan` carries, so it is the more
   invasive of the two.

The risk that argues against reading 1, and which the chosen design
must answer: exempting blocked items RAISES effective WIP, and a
session that keeps promoting into a phase full of blocked work can
accumulate unbounded blocked inventory. If reading 1 is taken, say
what stops that — a cap on the exempt count, or a `next` action that
surfaces a plan lane gone mostly-blocked.

## Non-goals

- **Not a change to any number in `LIMITS`.** The hard rules forbid
  widening a limit to make a move succeed, and this item is not a
  request to do so; it is about what the existing number COUNTS.
  Retuning the numbers is the flow review's job (`review.md`), and a
  fix here must be neutral to them.
- No change to what `blocked` means, to `block`/`unblock`, or to the
  blocker-edge predicate the fix reuses.
- No change to `next`'s ordering, beyond whatever falls out of a phase
  no longer being at its limit.
- Not a re-ranking or re-parenting of the four items in the evidence.

## Acceptance

- A test in `_work/flow_test.tl` building a `plan` lane of one claimed
  and three blocked items, asserting the occupancy and the rendered
  line against whichever reading the Change adopts. It must fail
  against `_work/flow.tl` as it stands.
- `gitboard status` over the reproduction above renders a `plan` lane
  that a promotion can enter (reading 1: `plan 1/4 (+3 blocked)`;
  reading 2: the three returned to `backlog`), quoted in the PR.
- `gitboard next` on that same board no longer falls through to
  `intake` — quote the action it names instead.
- `bin/cosmic --make ci` on the `board` branch: `ci: PASS`.

## Evidence commands

```
gitboard status | grep -E '^(plan|ready|do) ' -A6
gitboard next | head -3
sed -n '50,60p;168,190p' _work/flow.tl
grep -rn 'counts_against_limit' _work/*.tl        # empty
gitboard show 3I1VnwDm                            # the settled precedent
```

Measured 2026-08-28 against the `board` branch at `94241b0b`.
