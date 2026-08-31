# Problem

The board can now mark an outcome root held (`gitboard hold` /
`is_held`, built by the blocking board-tooling item) — a marker
distinct from `resolution`, reopened automatically when a child is
filed under it. Nothing documents the procedure, `docs/goals.md` has
nowhere to record a held outcome, and the tradeoff behind the
mechanism (marker over ending; the reopen rule) is not written down —
so the next reader either accepts the marker/ending split blindly or
reverses it blindly, both silent bugs in the project's direction per
the `decide` skill's own reasoning.

This is a normal `cosmic-lua/cosmic` PR: `docs/`, `skills/work/`, no
board-tooling involved. It depends on the mechanism existing (its
`blocked_by` blocker) so it documents the verb, field, and behavior
that was actually built, not a design that may have shifted in
review.

# Change

Four edits, all prose/docs, no code: a new `skills/work/decompose.md`,
one pointer line in `skills/work/SKILL.md`, a new `## Holding` section
in `docs/goals.md`, and a new decision record.

## `skills/work/decompose.md` (new file)

`ls skills/work/` today has only `SKILL.md` — `decompose.md` does not
exist, though `docs/decisions/d25-outcomes-and-instruments.md:28`
already points at it ("the method lives in
`skills/work/decompose.md`") for the paired-comparison tournament.
That gap is NOT this item's to close — write only what this outcome's
acceptance needs, two sections:

- **the VERIFICATION item form**: an item filed under an outcome root
  (`gitboard new "<title>" --parent <root-id> --spec-file ...`) whose
  `## Change` runs every `measured by:` command `docs/goals.md` names
  for that outcome and quotes the actual output, and whose
  `## Acceptance` is the outcome's `win condition:` line, quoted
  verbatim from goals.md. It is pulled, built, and reviewed exactly
  like any other slice — spec bar, `take`, PR, fresh-context review —
  no special-casing, which is the point: a session that did not do the
  goal's own work is the one judging whether the claim holds.
- **held-root intake behavior**: once the VERIFICATION item is
  accepted and merged, a session runs `gitboard hold <root-id>
  --reason '<why the win condition holds>'` (refuses on a non-root, an
  unopened item, an already-held one, or a blank reason). A held root
  stays open — `gitboard show` and `gitboard status` still find it —
  but `_work/intake.tl`'s walk treats it exactly like a root with live
  work: intake moves to the next-ranked open root without a hand edit.
  Filing or attaching a new item under a held root (fresh evidence
  that the win condition slipped) clears the hold in the same commit
  as the child, so the outcome is live again automatically —
  `gitboard hold`/`unhold` is for correcting an erroneous hold with no
  new child, not the normal reopen path.

## `skills/work/SKILL.md`

One line, in the same style as the existing `gitboard help <topic>`
pointer: name `skills/work/decompose.md` as where the decompose
procedure — including the verification-item form and a held root's
intake behavior — is documented. Do not restate the procedure here;
`SKILL.md` is deliberately the bootstrap only (its own words: "this
file deliberately restates none of it").

## `docs/goals.md`

Insert a new `## Holding` section. Measured insertion point (`sed -n
'218,224p' docs/goals.md`, 2026-08-31): G7's win-condition bullet ends
the "Outcomes, ranked" section at line 222, a blank line at 223, then
`## Instruments` at line 224 — insert the new section between them, so
it reads as the natural continuation of "outcomes" (an instrument is a
different category — how we see and steer, never itself held). Content
is a template only — no goal moves here in this PR (see Non-goals):

```markdown
## Holding

an outcome graduates here once a VERIFICATION item under it is
accepted and its root is marked held (`gitboard hold`) — see
`skills/work/decompose.md` for the procedure. each entry names the
outcome, the date it was verified, and the VERIFICATION item that
carries the evidence:

- `### G<n> — <original title>` — held YYYY-MM-DD, verified by
  `items/<id>` (PR #<n>); the `measured by:` output is quoted there.
  filing a new item under it reopens it automatically.

nothing is held yet.
```

## `docs/decisions/d<NN>-<slug>.md` (new record)

Next free number — check `ls docs/decisions/` at build time (`d39` is
the last one as of this writing; do not hardcode a number that may
have moved). Follow the `decide` skill's form exactly: H1 `# D<n> —
<the claim, lowercase>`, then `date`/`status: active`/`context`/
`decision`/`rejected`/`consequences`. Content, drawn from what the
board-tooling item actually built:

- **context**: roots are never phased, so the container-closure path
  (last child ends, parent returns to backlog, a session verifies and
  ends it) never applied to an outcome root; nothing recorded an
  outcome as held, and nothing let intake walk past one.
- **decision**: a marker (`is_held` on the item) distinct from
  `resolution`/`done`, set by `gitboard hold <root>` and cleared
  automatically the moment a child is filed or attached under it
  (`gate.containered`'s existing "parent gained a child" hook).
  Intake (`_work/intake.tl`) skips a held root exactly like one with
  live work; every other verb, gate, and the derived-order closure
  (`_work/priority.tl`) treat it as open, because it is.
- **rejected**: ending the root via `done --reason completed`. Two
  reasons it lost: no verb reopens a done item today (`set` explicitly
  refuses one — "a done item's facts are history, not a repair
  target"), so the acceptance requirement that fresh evidence reopens
  a held outcome would have needed a new reopen verb built from
  scratch; and `done`'s own gates (the PR-must-be-accepted check, the
  evidence-must-carry-a-verdict check) exist to protect a genuinely
  FINISHED item's history, which an outcome that might need to reopen
  is not.
- **consequences**: `_work/item.tl`, `_work/flow.tl`'s `roots`, and
  `_work/intake.tl` each carry one more field/branch to keep in step
  with `resolution`'s existing "done means what open does not" split;
  a held outcome's own gates keep enforcing it (it is never `done`),
  which is the property the marker was chosen to get for free.

# Non-goals

- Judging any specific goal held — the `## Holding` section ships
  empty (a template plus "nothing is held yet"); G9's (or any goal's)
  actual verification is its own item, blocked on this one.
- Retuning the outcome order or re-asking comparisons.
- Backfilling `skills/work/decompose.md`'s tournament-method section
  that D25 already promised — a real gap, but a different one; note it
  if noticed, file it separately.
- Any code change — the mechanism this documents is built entirely by
  the blocking board-tooling item.

# Acceptance

- `skills/work/decompose.md` exists and documents the VERIFICATION
  item form and the held-root intake behavior in the terms the built
  mechanism actually uses (`gitboard hold`/`unhold`, `is_held`, the
  automatic reopen-on-new-child).
- `skills/work/SKILL.md` points to it in one line, in its existing
  style.
- `docs/goals.md` carries a `## Holding` section between "Outcomes,
  ranked" and "Instruments", empty of any real goal.
- a new decision record under `docs/decisions/` states the tradeoff
  (marker over ending) and the reopen rule, in the `decide` skill's
  form, and `_build/docs_test.tl`'s index-derivation check
  (`cosmic --make test _build/docs_test.tl`) passes against it.
