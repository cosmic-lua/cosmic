# D45 — rank is a position in the parent's list at every level, the board included

- **date:** 2026-09
- **status:** active
- **context:** gitboard ordered a board by three separate mechanisms —
  the parent chain that gave an item its context, a `beats` relation
  that ranked whatever pair a session compared, and a `blocked_by`
  relation that lifted a prerequisite to sit where its waiter sat. each
  was derived honestly, and together they needed a seven-field
  `Position` record, several SQL views, a board-wide cycle walk, and
  doctrine repeated across a help page, a README section, a module
  header, and this project's own `skills/work/decompose.md`. read from
  the derived cache of the live board on 2026-09-05: a cross-subtree
  comparison raised the winner's dominance count but never moved it out
  of its own ancestor's band — the comparison answered a question
  parentage had already settled — and of 26 live `blocked_by` edges
  (both ends still open), 22 sat between siblings: a prerequisite filed
  beside the very item it blocked, paying for a whole edge kind, its
  cycle walk, and its doctrine to say what a child already says. the
  fuller evidence and the design that resolved it is
  [cosmic-lua/work's docs/design/order.md](https://github.com/cosmic-lua/work/blob/main/docs/design/order.md).
- **decision:** one mechanism replaces all three, at every level
  including the board's own:
  - an item's rank is a path: its position among its siblings at each
    level down from the board, the one parentless item. rank among
    siblings is a position in a list the parent holds; siblings not in
    the list follow it, by age. `gitboard help order` is the one
    statement of the rule, and every consumer of it — this record
    included — cites that page and restates nothing.
  - the board is an item like any other: the one parentless item,
    created by `init`, and its own `order` blob ranks its children (the
    outcomes) exactly as any parent's `order` ranks its children. an
    outcome the board's list does not position, and everything under
    it, is triage.
  - a prerequisite is a child of the item that waits on it, inheriting
    the waiter's rank prefix so it is ordered where the work it gates
    is ordered; the waiter is a container until the child resolves. a
    gap found mid-build is filed the same way: the question becomes a
    child of the stuck item, and the claim is released.
  - a verified outcome is `done --reason completed --by CHILD`, where
    CHILD is the outcome's own completed verification child; `done`
    refuses an outcome with an open child, a CHILD that is not its
    completed child, or no `--by` at all. filing or attaching a child
    under a done outcome clears its resolution in the same commit, so
    fresh evidence reopens it with no separate verb. retiring an
    outcome needs no child: `done --reason not-planned`.
  - the tool's vocabulary is board (parentless), outcome (its child,
    decomposed and never taken), container, and work — derived from
    depth and children alone, with no word for a goal, a tier, or an
    instrument.
- **rejected:**
  - **the comparison relation, with a global dominance count.** `beats`
    plus a per-item win tally (`own`) is what a list position already
    is, minus the property that a list cannot cycle; and the evidence
    above shows a cross-subtree comparison never moved a winner out of
    its ancestor's band, so the relation was buying a second answer to
    a question parentage had already closed.
  - **an integer rank field on the child.** two sessions can race to
    assign the same number, and every insertion renumbers every sibling
    across as many refs as there are siblings; a list position needs
    neither collision handling nor a renumbering pass.
  - **a global priority scale.** an asserted number with no forcing
    function drifts to the top of it the same way an unranked list
    would, without even the paired-comparison discipline that made
    `beats` land somewhere principled.
  - **a separate root-list ref** (`refs/heads/board/order`, stored
    beside `seq` and `format`, as an early draft of this design kept
    it). making the board itself the one parentless item removes the
    special case: its own `order` blob does the identical job with no
    second list to keep in sync and no root-case branch in the
    derivation.
  - **keeping `blocked_by` as a non-ranking, informational edge.**
    22 of 26 live edges already sat between siblings, so the edge
    duplicated what parentage said for all but four; keeping a whole
    edge kind, its cycle walk, and its doctrine section to serve four
    items was not a trade worth making.
  - **a held marker distinct from `resolution`**
    ([D42](d42-held-outcome-is-a-marker-not-an-ending.md)). reopening a
    held root and reopening a done one turned out to need the identical
    hook (`gate.containered`: filing a child under either clears it in
    the same commit), and D42's own reason for not using `done` — its
    gates protect a PR-bearing leaf's history — is answered directly by
    `--by CHILD` rather than by keeping a second, parallel "verified"
    state next to `resolution`.
- **consequences:** the verb surface shrinks — `compare`, `hold`,
  `unhold`, `block`, and `unblock` are gone; `rank ID --before X |
  --after X | --last` replaces all three at every level, outcomes
  included, and `new`/`attach` gain `--before`/`--after` to place an
  item the moment it arrives. `gitboard migrate` moves a layout-1 board
  onto the new layout in one commit: each `beats` closure becomes an
  `order` list under the common parent (winners first, ties by age),
  each live `blocked_by` edge re-parents the blocker under its waiter,
  and each held root becomes a done one. every consumer of the old
  vocabulary now cites `gitboard help order` instead of restating it:
  this project's `docs/goals.md`, whose outcome list is prose written
  out for a reader from the board's own ranking — changing the order
  means re-ranking on the board with `gitboard rank` and landing the PR
  that rewrites the list, not asking a tournament of contested pairs —
  and `skills/work/decompose.md`, whose ranking section now walks the
  list rather than the tournament. what this forbids: any doc in this
  tree restating the ordering rule in its own words rather than citing
  the page it lives on.
