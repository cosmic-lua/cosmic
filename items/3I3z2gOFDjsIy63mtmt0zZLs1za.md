## Goal

G8 — the flow system. The board claims ALL work state ("never in GitHub labels,
issue comments"), but that claim stops at the whilp/cosmic remote. Work against
whilp/cosmopolitan — the C core every cosmic pin bump carries — has nowhere to
live on the board, so it falls back to exactly the label mechanism the board
superseded, or to nothing at all.

## Evidence (verified 2026-08-17)

- whilp/cosmopolitan has no `board` branch: `git ls-remote --heads origin board`
  returns nothing.
- whilp/cosmopolitan#265 is open, unfixed, and carries `work:ready` — a
  fully-shaped spec (Goal / Change / Non-goals / Acceptance / Enablement) living
  as an issue body, with its phase carried by a label. It is the ONLY `work:*`
  label among the repo's 12 open issues; the `perf` (3) and `audit` (3) labels
  are intake queues the skill already exempts, so the leak is one stranded item,
  not a parallel workflow in daily use.
- #265's pointer is buried: G5 (3HyEE7RJ, ended completed 2026-08-17) named it
  as a "future child, opened there when this epic's cosmic-layer children prove
  the pattern". That epic ended; nothing on the live board names #265. Its goal
  (3HyRck1p, G5 — adversarial verification) is still open with live children, so
  the work is in scope and simply invisible.
- `_work/item.tl`'s `Item` record has no repo field, so no item can say which
  repo it is about.
- The GitHub-facing verbs are not hardcoded to whilp/cosmic, but they are
  single-repo by construction: `_work/gh.tl`'s `slug` reads `git remote get-url
  origin` on the STATE checkout, and the state checkout is the board branch of
  whilp/cosmic. Every `pull`, `checks` and `merge` call therefore addresses that
  one slug. A per-item repo would have to be threaded through `slug`'s three
  callers, not just added to the record.

## Change (direction settled 2026-08-17)

One board, here. whilp/cosmic's board grows the ability to hold an item whose
diff lands in another repo; whilp/cosmopolitan does NOT get its own `board`
branch. A second board would duplicate the machinery, split the goal trace that
makes cross-repo work legible in the first place (a cosmopolitan fix exists to
serve a cosmic goal — #265 serves G5), and give a repo with no cosmic toolchain
a cosmic project to build.

The shape to build: an item field naming the repo its PR lands in, defaulting to
the board's own origin so every existing item is unchanged; `_work/gh.tl`'s
`slug` reading that field instead of only the checkout's origin, so `move ...
check` and `land` address the right repo; and the views (`show`, `tree`,
`status`) surfacing a non-default repo, since an item that reads as cosmic work
but merges elsewhere is the failure mode this is fixing.

## Non-goals

No `board` branch on whilp/cosmopolitan. No move of the `perf` backlog (the
optimize skill owns it) or the `audit` label off issues — issues remain the
inbound queue. No generalization past the two repos this project actually
spans.

## Still to settle before ready

- The field's name, type and default, and whether an unset field means "the
  board's origin" or is written out explicitly at `new` time.
- Whether the credential the verbs use reaches whilp/cosmopolitan, and what
  `land` does when it does not — a refusal that names the repo, presumably, but
  it needs the same treatment as 3I06cBmI's 403 branch.
- Acceptance commands, and whether importing #265 as the first cross-repo item
  is part of this slice or the item that follows it. Either way #265 gets a real
  tracked item once the mechanism exists; today nothing on the board names it.
