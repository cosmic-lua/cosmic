## Goal

G8 — the flow system. Four passages in `skills/work/**` on `main` still
describe review distance as something the board machinery enforces by
identity. `3IYiZ9Md` moved the rule into the review procedure and
`3IYYwdp7` deletes the machinery, but `3IYYwdp7` is board-branch only and
carries `Do NOT touch skills/work/**` as a non-goal, so nothing removes
these. The moment `3IYYwdp7` lands, the skill instructs sessions to rely
on a gate that no longer exists.

## Evidence

Measured against `main` at PR #1492's head (the branch that landed
`3IYiZ9Md`). Each passage names a mechanism `3IYYwdp7` removes:

**`skills/work/SKILL.md`, the "what IS still split" paragraph near the
top** states that "`next --session NAME` never hands a session a verdict
on work that session built — the claim recorded when it pulled the item
survives into `check` and says who did it", and concludes "that distance
is now a property of the board rather than of which model is running".
After `3IYYwdp7` both sentences are false: `action.reviewable` stops
testing `built_by`, and the distance is a property of the review
subagent's context window.

**`skills/work/SKILL.md`, the "do not invent that name" paragraph**
argues that a reused session name "makes every item it touches
unreviewable by the next run — the collision is silent and durable,
because the builder is remembered". Unique names still matter for CLAIMS,
which is the paragraph's real subject; the unreviewable consequence is
the deleted gate.

**`skills/work/review.md`, the "claim before you read" paragraph** ends
"The claim is mutual exclusion, not authority — any non-builder's verdict
stands and consumes it." `non-builder` names the removed test. The
sentence's point survives verbatim as "any verdict stands and consumes
it".

**`skills/work/loop.md`, the whole "minted identities and the verdict
wall" section** is built on the gate: "`built_by` matches names exactly,
so `next` will happily offer this session a verdict on its own wave's PR
under its minted name", and the wall it draws sends such items to "wait
in `check` for a session that did not drive them". With the review in a
fresh-context subagent that never held the wave, waiting for a different
SESSION is no longer what makes the judgment disinterested — the
orchestrator spawning the review is the intended path. The minted-claim
half of the section (unique suffixes so claims lock, orchestrator prefix
so provenance is readable) is unaffected and must survive.

## Change

`skills/work/{SKILL.md,review.md,loop.md}`, prose only. Each passage
keeps what it says about CLAIMS and drops what it says about the identity
gate withholding a verdict.

**`loop.md`'s verdict-wall section is already rewritten**, by
`3IYiZ9Md`: it is now `## minted identities and your own wave`, and it
states the rule this item's other passages are being converged on — an
orchestrator may take the verdict on its own wave, because the review
runs in a subagent whose window never held the build. That section needs
no rewrite here.

**What it does need is its `next` clause dropped.** The rewritten
section tells a pass that `next` does not offer an item whose claim or
`builders` name this session, and that the review subagent is therefore
spawned on the id step 1 reconciled rather than waited for; step 3 names
the same id source and the `never blocked` table carries the matching
row. Deleting `built_by` makes the first half false — `next` then offers
a session its own wave like any other item — and the second half merely
one way to reach the item rather than the only one. Drop the withholding
clause, drop the `never blocked` row it feeds, and let step 3 say that
`next` offers the item. The section's other three statements — the rule,
the brief, the audit record — are unaffected and stay verbatim.

## Non-goals

- No change to `_work/**`; the machinery is `3IYYwdp7`.
- Do not relax the review-isolation rule `3IYiZ9Md` installed, and do not
  reintroduce an identity check under another name.
- Do not remove `builders` or any prose describing it as the audit record
  of who held a claim.
- Do not change the three verdicts, the six review checks, or the verdict
  grammar.

## Acceptance

Run from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c 'non-builder' skills/work/review.md` prints `0`.
- `grep -c 'built_by' skills/work/loop.md` prints `0`.
- `grep -c 'unreviewable by the next run' skills/work/SKILL.md` prints `0`.
- `grep -c 'a property of the board' skills/work/SKILL.md` prints `0`.
- `grep -c 'withholds' skills/work/loop.md` prints `0` (`1` once
  `3IYiZ9Md` has landed) — the `next` clause and its `never blocked` row
  are gone.
- `git diff --name-only origin/main` lists only files under `skills/work/`.

Note that each `grep -c` above matches a phrase that sits on one line in
the file today; a rewrite that reflows the paragraph can make a count
pass for the wrong reason, so read the file rather than trusting the
count alone.

## Ordering

This must land AFTER `3IYYwdp7`, or the skill would describe a gate that
is still running. It is not a blocker on `3IYYwdp7` — the gap is prose
that is briefly redundant, not prose that is briefly wrong.
