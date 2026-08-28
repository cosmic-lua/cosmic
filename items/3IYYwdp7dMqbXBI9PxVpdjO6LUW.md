## Evidence

The no-self-accept guard keys on HAVING HELD THE CLAIM, not on having
authored the artifact under review. `_work/flow.tl:433-444`:

```teal
local function built_by(i: Item, session: string): boolean
  local who = root(session)
  if root(i.claim or "") == who then
    return true
  end
  for _, name in ipairs(i.builders or {}) do
    if root(name) == who then
      return true
    end
  end
  return false
end
```

`builders` is appended by `item.record_builder` (`_work/item.tl:298`),
called from exactly one place — `_work/gitverbs.tl:251`, inside `if claim
~= nil and claim ~= "" then`. So every move that sets a claim records a
builder, whatever that claim went on to produce: a merged PR, a closed
one, a branch abandoned before any PR, or a takeover.

**Measured 2026-08-28.** `3IUBNQZZ`:

```
["builders"] = "0b13d2b4-… e532d9f6-… 0b13d2b4-…/3IUBNQZZ"
["claim"]    = "05f7c552-…"
["pr"]       = 1485
```

Session `0b13d2b4` is in `builders` because its agent held the claim and
built **PR #1484**, which is CLOSED — closed by that session as a
duplicate once `05f7c552` produced #1485 for the same item. The diff
awaiting judgment is #1485, which `0b13d2b4` did not write. The guard
fires on a claim held over a discarded competitor.

`3IVLAF3Z` is the same shape from a different route: `0b13d2b4` appears
from an earlier bounce-and-refine cycle, while `claim` and `pr` are
`05f7c552`'s.

**The consequence, today.** `05f7c552` authored both diffs, so the guard
withholds them from it correctly. `0b13d2b4` is in `builders` on both, so
the guard withholds them from it too. Neither active session can give
either verdict. `status` reads `check 5/10`, `ready 2/5`, `WIP ok; ready
starved`, and `next` reports **27 blocked and skipped** — every one of
them downstream of two PRs that are green, mergeable, and unjudgeable.

**A second artifact of the same conflation.** `record_builder` dedupes by
EXACT name (`if name == session then return end`) while `built_by`
compares by `root`, so an orchestrator that pulls under a bare id and
again under a minted `<session>/<item>` claim lands twice in the list —
visible above as `0b13d2b4-…` and `0b13d2b4-…/3IUBNQZZ`. Harmless to the
verdict, but it shows the list is a log of claim events rather than a set
of authors.

## Why this is not a case for "more than one session participated"

The obvious relaxation — admit a reviewer once the participant set
exceeds one — **admits the case the rule exists to prevent**. For
`3IUBNQZZ` that set is `{0b13d2b4, e532d9f6, 05f7c552}`, three sessions,
so `05f7c552` could accept #1485, which `05f7c552` wrote. It buys the
unblocking by permitting exactly the thing the wall is for.

## The shared root cause with 3IY2Bj90

Claim-holding is a PROXY for authorship, and it is wrong in both
directions. This item is the over-firing half: a claim that produced
nothing under review disqualifies. `3IY2Bj90` is the under-firing half:
writing an item's spec touches only the `.md` sidecar, records nothing,
and so never disqualifies — a session was offered the review of #1480
having written the sentence that picked its route.

The two are siblings rather than one item because they do not share a
fix. Re-keying the guard on the artifact under review closes this one and
leaves spec authorship exactly as invisible as it is now; recording spec
authorship closes that one and leaves a discarded build still
disqualifying. A single change keyed on the KIND of participation might
close both, but asserting that is a design decision, not a measurement.

Participation kinds the record currently collapses into one bit:

| kind | should it bar a verdict? |
|---|---|
| authored the diff under review | yes, absolutely |
| authored the spec the diff implements | compromised on "was this worth building", not on conformance |
| built a competing diff, since discarded | arguably the best-informed reviewer |
| took over a stale claim | deliberate today (`_work/gitverbs.tl:240-242`) |
| bounced it back to `plan` with a gap named | no — and correctly does not, since a bounce sets no claim |

## Not asserted here

Which fix. Candidates, each trading differently: key `built_by` on the
claim that produced the item's current `pr`; record a kind alongside each
name in `builders` and let the guard read it; keep the guard and give
`verdict` a reviewed escape for the discarded-competitor case. The first
is the narrowest and needs no format change; the second is the only one
that could also close `3IY2Bj90`. The choice belongs in `plan`, and it is
a change to `_work/flow.tl`, which is board machinery and lands by the
branch's own review path.
