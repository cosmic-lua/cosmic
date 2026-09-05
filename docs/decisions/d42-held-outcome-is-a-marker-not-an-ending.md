# D42 — a verified outcome is held by a marker, not ended; a child filed under it clears the hold

- **date:** 2026-09
- **status:** superseded by D45
- **context:** the board's items end one way: `gitboard done --reason
  completed|not-planned` writes a `resolution`, and a non-empty
  resolution IS what "done" means (`_work/item.tl`). a container
  whose last child ends returns to the backlog, a session verifies it,
  and ends it the same way. an outcome root — a `G<n>` in
  `docs/goals.md`, placed in the derived order by `beats` edges
  ([D25](d25-outcomes-and-instruments.md)) — never took that path:
  roots are never phased, so nothing ever handed one back for closure,
  nothing recorded that its win condition had been verified, and
  intake (`_work/intake.tl`) kept offering it for decomposition
  forever. as G4 approached holding (goals.md marks it "near
  holding"), the gap became concrete: the next reader would either
  end the root with `done` or hand-edit goals.md, and neither leaves
  intake able to walk past a verified outcome while keeping it
  reopenable when its win condition slips. `_work/gitgraph.tl`'s
  `set` already refuses a done item outright — "a finished item's
  facts are history, not a repair target" — and no verb reopens one.
- **decision:** a held outcome is an open root carrying a marker.
  - `is_held` is a boolean on the item, distinct from
    `resolution`/`done`; `item.problems` refuses it on anything but a
    root. `gitboard hold <root> --reason WHY` sets it, refusing a
    non-root, a done item, an already-held root, and a blank reason;
    the reason rides in the commit subject and the verdict line, so
    the log is the record, exactly as it is for a comparison (the
    `compare` verb's module, since retired).
  - the marker clears automatically the moment a child is filed or
    attached under the root: `gate.containered` in `_work/gitgate.tl`
    — the hook that already clears a parent's claim and reviewer when
    it gains a child — clears `is_held` in the same commit as the
    child, so fresh evidence under a held outcome reopens it with no
    separate verb and no window where the child exists but the root
    still reads held. `gitboard unhold` exists only to correct an
    erroneous hold with no child to file.
  - intake skips a held root exactly like one with live work:
    `flow.roots` (`_work/flow.tl`) returns held ids as a third value
    and `_work/intake.tl` walks past them to the next-ranked open root.
    every other verb, gate, `show` (bare or by id), and the derived-order
    closure (the priority module, since retired) treat a held root as
    open, because it is — it keeps every edge and its position.
- **rejected:**
  - ending the root with `done --reason completed`. two reasons it
    lost. first, no verb reopens a done item, and `set` refuses one on
    purpose — "a done item's facts are history, not a repair target"
    — so the requirement that fresh evidence reopens a held outcome
    would have needed a reopen verb built from scratch, against the
    grain of an append-only history that treats an ending as final.
    second, `done`'s own gates — the PR-must-be-accepted check, the
    evidence-must-carry-a-verdict check — exist to protect a genuinely
    FINISHED item's history; an outcome that must stay reopenable is
    not finished, and running it through gates built for the opposite
    property would have either weakened those gates or misfiled the
    outcome as something it is not.
  - a hand edit to goals.md alone (moving the goal under `## Holding`
    with no board fact). intake reads the board's derived order, not
    the goals file, so a prose move leaves intake offering the held
    root forever; and a fact with no verb behind it is one no gate can
    enforce or refuse.
- **consequences:** `_work/item.tl` (the field and its root-only
  guard), `_work/flow.tl`'s `roots` (the third return), and
  `_work/intake.tl` (the skip) each carry one more field or branch, in
  step with `resolution`'s existing "done means what open does not"
  split; a fourth place that decides what a root is for must remember
  the marker too. a held outcome's own gates keep enforcing it — it is
  never `done`, so a claim, a review, or a new child under it meets
  every check an open root does — which is the property the marker was
  chosen to get for free. goals.md's `## Holding` section is the
  human-readable mirror of the marker and is edited by hand in the
  same change that runs `hold`; the two can drift, and the board is
  the authority when they do. revisit if a held outcome ever needs to
  become genuinely final — an outcome retired rather than verified —
  which is `done --reason not-planned`, not a hold.
