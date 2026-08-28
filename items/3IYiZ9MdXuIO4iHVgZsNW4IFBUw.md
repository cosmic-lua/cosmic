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

**6. `skills/work/review.md` and `skills/work/SKILL.md` — the review
subagent NAMES ITSELF.** State in `review.md`, where the subagent is
established, that it exports `GITBOARD_SESSION` set to a value unique to
that review before running `gitboard verdict`, and why: a subagent
inherits the session id of the process that spawned it, so an unnamed
reviewer resolves to the BUILDER's identity and the board records the
verdict under the session whose window held the work. The identity is
what makes the isolation checkable afterwards; no gate can inspect a
context window. `SKILL.md`'s session-identity paragraph carries the
matching carve-out, or it contradicts this: a review subagent is the
case where the derived value is WRONG rather than absent, so it names
itself, and that is not the inline invention the paragraph warns
against. What that paragraph says about CLAIMS stays as it is.
`loop.md` takes the same one-clause correction wherever it states the
audit-trail promise: the verdict's identity is exported, not derived.

**7. `skills/work/loop.md` — rewrite the `## minted identities and the
verdict wall` section.** The wall goes and isolation carries the whole
distance: a subagent whose window never held the build is disinterested
however it was spawned, so nothing is left for the wall to add. Rename
the heading to the subject the section now has — the orchestrator's own
wave — and keep the minted-claim paragraph exactly as it is (unique
suffixes so claims lock, the orchestrator prefix so provenance stays
readable in the log). The wall's paragraphs are replaced by four
statements:

- **the rule.** An orchestrator may take the verdict on its own wave.
  The review runs in a subagent whose window never held the build —
  not the brief that spawned the builder, not the agent's report, not
  the pass's reasoning about the item — so this is `review.md`'s rule
  reaching the case a loop meets every pass, not an exception carved
  out of it.
- **the brief.** The distance is only as good as the brief: it carries
  the item id, the PR number and the checks, and NOT the session's own
  reading of the item, because a brief that summarises what the wave
  was trying to achieve hands the reviewer back the commitment a fresh
  window exists to be without.
- **the audit record.** The claim and `builders` say who held the item
  and who built it; the verdict carries the review subagent's own
  exported name. This is Change 6's audit-trail correction, landing
  inside the rewritten section rather than beside it.
- **what `next` does with it.** `next` does not offer an item whose
  claim or `builders` name this session — names compare by the claim's
  prefix, so work a minted agent built reads as the orchestrator's own
  — and it steps over such an item silently. So the review subagent
  is spawned on the item id directly, the one step 1 reconciled into
  `check`, rather than waited for. Step 3 names the same id source and
  the `never blocked` table gains the row. Say nothing about when the
  stepped-over count surfaces: both `none` returns under `if ph.mine >
  0 or ph.reviewing > 0` in `_work/action.tl` carry that count, and the
  WIP limit only selects which sentence carries it. Measured by calling
  `action.next_action` with `check` below its limit and at it:

  ```
  check at 1/10  → nothing in check is this session's to judge
                   (1 built by this session, 0 under another session's
                   review) — their verdicts land elsewhere
  check at 10/10 → check is at 10/10 with nothing this session may
                   judge (10 built by this session, 0 …) — nothing can
                   be handed over until a verdict lands
  ```

Write all four as properties of the tool in the skill's own voice: no
history, no item references, no interim framing.

**8. `skills/work/parallel.md` — the `do not merge` bullet's landing
clause.** "a PR lands only after an accept, in a later pass by a
session that did not build it" asserts the identity doctrine this item
retires, and it contradicts the loop's own landing step, which lands a
wave's accepted PRs on the next pass of the session that spawned the
wave. Correct that one clause. What the bullet tells the AGENT is
unchanged: it does not merge, and its loop ends at the opened PR.

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
- `grep -c 'GITBOARD_SESSION' skills/work/review.md` prints at least
  `1` (`0` today).
- `grep -c 'N agents reviewing N PRs' skills/work/parallel.md` prints
  `1` (`1` today) — the prohibition survives the split.
- `grep -c 'verdict wall' skills/work/loop.md` prints `0` (`1` on
  `origin/main`) — the section is renamed, not merely reworded.
- `grep -c 'may take the verdict on its own wave' skills/work/loop.md`
  prints `1` (`0` on `origin/main`).
- `grep -c 'withholds' skills/work/loop.md` prints at least `1` (`0` on
  `origin/main`) — the pass is told what `next` does with its own wave.
- `grep -c 'surfaces only when' skills/work/loop.md` prints `0` (`1` at
  the PR head) — the pass is not told a false thing about when `next`
  names the count it stepped over.
- `grep -c 'a session that did not build it' skills/work/parallel.md`
  prints `0` (`1` on `origin/main`).
- `wc -l skills/work/SKILL.md` is at most `500` (`456` at the PR head);
  `review.md` at most `500` (`308`); `parallel.md` at most `500` (`210`);
  `loop.md` at most `500` (`142`).
- `git diff --name-only origin/main` lists only files under
  `skills/work/`.

## Enablement

`none needed`. Markdown only, no blocker: `3IYYwdp7` depends on THIS
item rather than the other way round, and the ordering exists so no
window has neither the gate nor the procedure carrying the rule.
