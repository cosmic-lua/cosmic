## Goal

G8 — the flow system. Review distance moves from an identity gate in the
board machinery to a CONTEXT gate in the review procedure: the review runs
in a subagent whose window holds the diff and the spec and nothing else.
A fresh context cannot be biased by context it does not have, which is the
property the identity gate was a proxy for.

This item lands the procedure. `3IYYwdp7` removes the machinery gate and
is BLOCKED on this one, so the skill is carrying the rule before the
machinery stops.

## Evidence

Measured 2026-08-28 against `origin/main`. Four files, all under the
500-line cap with room:

```
wc -l skills/work/{SKILL.md,review.md,parallel.md,loop.md}
  450 SKILL.md   286 review.md   206 parallel.md   124 loop.md
```

**The rule already exists in prose and relies on the machinery to bind.**
`review.md:11-16` says "**never your own** … honour it if you reach for
`verdict` directly", and its reason is the identity gate: "the claim
recorded when the item was pulled survives into `check`". When the gate
goes, that paragraph names a mechanism that no longer exists.

**`parallel.md:173-180` forbids what this item requires, for a different
reason than it appears.** Its clause reads:

> **the review verdict.** it is the system's final gate and a
> sophisticated model's judgment (`review.md`); N agents reviewing N PRs
> is N unreviewed merges wearing a costume.

That argues against fanning out N reviews for THROUGHPUT — quantity
displacing judgment. It does not argue against running ONE review in an
isolated context. The two need separating, not reversing.

**`loop.md:32-33` states the same thing operationally**: "review what
`next` offers to review — inline, in this session, never fanned out".

**Why a subagent and not an instruction to be skeptical.** Observed today
on `3IUBNQZZ`. The session building a competing implementation found that
the item's second Acceptance bullet specifies a compare the gate refuses
before any table prints, and reported it as "a pre-existing gate property
this item is fenced out of touching, **not a defect in the change**". The
disinterested reviewer found the same thing and filed it as `3IYZ3jII`,
"an Acceptance command can reach `ready` unrun". Same observation,
opposite disposition. Asking a session to be skeptical operates on a
session that still holds the commitment; a fresh window does not have it.

## Change

**1. `skills/work/review.md` — replace the `never your own` paragraph
(`:11-16`) with the isolation rule.** State: the review runs in a
subagent with a fresh context, spawned for that one item; the brief
carries the item id, the PR number and the six checks, and NOT the
orchestrator's reasoning about the item; the subagent reads the spec and
the diff from the board and GitHub itself. State the reason in one line —
a fresh window cannot be biased by context it does not hold. Keep the
existing sentence that `check` is the only phase a verdict may end.

Add to the same section: the subagent runs `gitboard verdict` ITSELF, so
the identity the board records is the reviewer's own, not the
orchestrator's. That is the audit trail — the log then shows whether
reviews were run in isolation, which no gate can verify.

**2. `skills/work/review.md` — strengthen the adversarial posture.** The
six numbered checks stay as they are. Add, in the `## the review itself`
preamble, that the reviewer's job is to try to make the diff fail: run
the acceptance commands rather than reading them, and mutation-test at
least one guard the change adds — break it, watch the test go red,
restore it. A gate that cannot be shown to fail is decoration.

**3. `skills/work/parallel.md` — split the `what never fans out` clause
(`:175-177`).** Keep "N agents reviewing N PRs in parallel" forbidden,
with its existing reasoning. Add that ONE review in ONE isolated subagent
is required, not forbidden, and that the distinction is throughput versus
context — the rule was never about where the review runs.

**4. `skills/work/loop.md` — rewrite step 3 (`:32-33`).** "inline, in
this session, never fanned out" becomes: spawn one review subagent, wait
for it, act on its verdict. One item per pass stays.

**5. `skills/work/SKILL.md` — the hard rule at `:435` and the
session-identity paragraph.** The rule "no session accepts its own work"
keeps its name and loses its mechanism sentence ("the derived session
identity enforces it in `next`"): it is now carried by the review
procedure, and `SKILL.md` says which. The session-identity paragraph
keeps everything it says about unique names for CLAIMS — that half is
unaffected — and drops the clause about withholding a verdict.

## Non-goals

- Do NOT touch `_work/**`. The machinery removal is `3IYYwdp7`, and it
  lands after this. This item is markdown only.
- Do not change the three verdicts, the six review checks, or the
  verdict grammar in `review.md`. The posture strengthens; the contract
  does not move.
- Do not remove `builders` from the item record or from any prose that
  describes it as an audit trail — `3IY2Bj90` wants more recording, not
  less.
- Do not relax the N-parallel-reviews prohibition in `parallel.md`.
- Do not touch `decompose.md` or `enable.md`.
- No change to `docs/goals.md`.

## Acceptance

Run from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c 'never your own' skills/work/review.md` prints `0` (`1`
  today).
- `grep -c 'subagent' skills/work/review.md` prints at least `2` (`0`
  today).
- `grep -c 'inline, in this session' skills/work/loop.md` prints `0`
  (`1` today).
- `grep -c 'derived session identity enforces it' skills/work/SKILL.md`
  prints `0` (`1` today).
- `grep -c 'N agents reviewing N PRs' skills/work/parallel.md` prints
  `1` (`1` today) — the prohibition survives the split.
- `wc -l skills/work/SKILL.md` is at most `500` (`450` today);
  `review.md` at most `500` (`286`); `parallel.md` at most `500` (`206`);
  `loop.md` at most `500` (`124`).
- `git diff --name-only origin/main` lists only files under
  `skills/work/`.

## Enablement

`none needed`. Markdown only, no blocker: `3IYYwdp7` depends on THIS
item rather than the other way round, and the ordering exists so no
window has neither the gate nor the procedure carrying the rule.
