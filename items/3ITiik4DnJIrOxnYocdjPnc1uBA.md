`gitboard next` hands out a `finish` action for an item in `land` even
when that item carries an open blocker, so a blocker recorded against
a `land` cannot hold the merge and the loop cannot get past it.

Observed 2026-08-27. `3ITerUZf` was accepted into `land` with
`pr: 281`, then blocked on `3ITicXY1` with a reason. `gitboard status`
renders it correctly — `land 1 / 3ITerUZf ... pr:281 [blocked]` — but
`gitboard next` still answers:

```
gitboard-next: finish 3ITerUZf ... — land holds 1 — 3ITerUZf is
accepted, awaiting merge
```

and repeats that answer on every subsequent call, because nothing else
can be offered while `land` is non-empty. A session that declines the
merge for a stated reason therefore stalls: the ordering has exactly
one answer and it is the action being withheld.

The other phases appear to consult blockers — `ready`'s sole item
`3ISVlHT6` is `[blocked]` and `status` reports "every ready item is
blocked; the chain bottoms at `3ITVR6Ku`", which is a routing decision
the ordering made — so this looks like `land` being the one phase
whose action is emitted unconditionally rather than a deliberate rule
that a judged item merges regardless.

Two shapes a fix could take, neither chosen here: `next` could route
past a blocked `land` the way it routes past blocked `ready` work and
name the blocker in the flow note, or `block` could refuse an item in
`land` outright, which would say that the merge is not a thing a
blocker may hold and force the wait to be recorded some other way
(a `request changes` verdict, or a return to `check`). The first
matches how blockers read everywhere else. Whichever it is, the
current combination lets a session record a wait the ordering then
ignores, which is worse than either.
