## Goal

G8 — the flow system: the board runs the work. An order the board
renders has to mean what the tool says it means, or every `promote`,
`sweep` and `next` downstream of it is choosing against the wrong
neighbours.

## Problem

`compare A B` between two leaves that inherit their band **lowers both
of them**, which is the exact opposite of the contract the module
states about itself.

`_work/priority.tl:14-26` promises:

> `band` is what lets a comparison at any height place everything
> beneath it: a leaf nobody compared inherits its parent's standing, so
> decomposing an item never costs it its position, and **comparing two
> leaves refines the order INSIDE a band without disturbing the bands
> themselves.**

The second half is false whenever the two leaves are placed by
INHERITANCE rather than by an edge of their own — which is the normal
state of every item `attach` ever placed.

### Reproduction, run against the live board 2026-08-28

Two backlog leaves, each placed through its parent, neither carrying an
edge:

```
gitboard show 3IY0HUUk | grep -E '^(parent|priority):'
  parent: 3HyRdABz…   (G4)
  priority: band 3, outranks 0
gitboard show 3IUKyP4L | grep -E '^(parent|priority):'
  parent: 3IOCdooE…   (under G5)
  priority: band 6, outranks 0
```

Record one comparison between them — an order-refining judgment that
should touch nothing else:

```
gitboard compare 3IY0HUUk 3IUKyP4L
  gitboard-compare: 3IY0HUUk now outranks 3IUKyP4L (band 1, outranks 1)
```

Both fell, and the winner of the comparison fell furthest relative to
where it sat:

```
3IY0HUUk  band 3 -> band 1     (dropped 2 bands by WINNING)
3IUKyP4L  band 6 -> band 0     (dropped 6 bands)
```

`uncompare` restores both exactly, so the state is recoverable and no
data is lost:

```
gitboard uncompare 3IY0HUUk 3IUKyP4L
  gitboard-uncompare: 3IY0HUUk no longer outranks 3IUKyP4L (band 3, outranks 0)
3IY0HUUk  band 3, outranks 0
3IUKyP4L  band 6, outranks 0
```

### Mechanism

`_work/priority.tl:255-266` walks self-then-ancestors and stops at the
FIRST item that carries an edge:

```teal
for _ = 1, MAX_DEPTH do
  if has_out_edge(index, cur) or beaten[cur.id] then
    band = own[cur.id] or 0
    break
  end
  ...
end
```

`cur` starts at the item itself. So the moment a leaf gains any edge —
as either side, since `beaten[cur.id]` counts too — the walk terminates
at self and `band` becomes that leaf's own dominance count instead of
the ancestor's. A leaf that dominates one other leaf gets `band = 1`; a
leaf that is merely beaten gets `band = 0`. Both numbers are computed
from a two-item comparison graph and have nothing to do with the bands
the two items were sitting in.

The invariant the comment describes holds only in the case where both
leaves ALREADY carry edges, which is not the case any ordinary
`compare` call meets.

### Why it matters beyond the surprise

This is the failure mode the skill explicitly steers sessions toward.
`SKILL.md` tells a session that a comparison "commits one judgment"
and that placing low "asserts nothing anyone has to trust", and
`decompose.md` treats `compare` as the cheap, reversible instrument for
refining order. A session following that advice on two inherited-band
leaves silently demotes both — including, in the reproduction above, the
item it just judged MORE important. Nothing in the verdict line says a
band moved: it prints the new band as though it were a result, not a
side effect.

## Change

Decide and implement which half of the contradiction is the intended
design, then make source, behaviour and prose agree.

The two candidate readings, both defensible:

1. **The comment is right and the walk is wrong.** A leaf's band should
   stay inherited unless a comparison reaches it from ABOVE its own
   level; comparisons among peers order them within the band via `own`,
   which is what `own` is already for. The fix is in the walk's
   stopping condition — an edge to a peer must not terminate it.
2. **The walk is right and the comment is wrong.** Carrying an edge
   really does mean "this item is placed on its own merits now", and
   the comment's promise must be deleted rather than implemented. If
   this is chosen, `compare` must SAY so — a verdict line that names
   the band each side moved from and to, so the demotion is visible at
   the moment it happens — and `SKILL.md`/`decompose.md` must stop
   describing `compare` as free of positional side effects.

Reading 1 is the one the rest of the system appears to assume; do not
treat that as settled without checking `_work/priority_test.tl`, whose
existing cases may already pin one reading.

## Non-goals

- No change to `own`, to the transitive closure, or to how `uncompare`
  works — the recovery path is correct today and is what makes this
  safe to work on.
- No change to `placed` or to the `check` gate that refuses to promote
  unplaced work. The comment at `priority.tl:269-271` explains why
  `placed` is deliberately not lifted; leave it.
- Not a re-ranking of any item. This is the mechanism, not the order.

## Acceptance

- A test in `_work/priority_test.tl` that builds two leaves under
  DIFFERENT parents at different bands, records one comparison between
  them, and asserts the resulting bands against whichever reading the
  Change adopts. The test must fail against `_work/priority.tl` as it
  stands if reading 1 is adopted.
- The reproduction above, re-run end to end on a scratch board, with
  the four `band N, outranks M` readings quoted.
- `bin/cosmic --make ci` on the `board` branch: `ci: PASS`.
- The `priority.tl` header comment and the behaviour agree, quoted side
  by side in the PR.

## Evidence commands

```
gitboard show 3IY0HUUk | grep -E '^(parent|priority):'
gitboard show 3IUKyP4L | grep -E '^(parent|priority):'
gitboard compare 3IY0HUUk 3IUKyP4L      # then uncompare — see above
sed -n '14,26p;250,275p' _work/priority.tl
```

Measured 2026-08-28 against the board branch at `62244ff3` and the
`_work/priority.tl` carried there.
