## Goal

G8 — the flow system. Six passages in `skills/work/**` on `main` still
describe review distance as something the board machinery enforces by
matching session identities. `3IYiZ9Md` moved the rule into the review
procedure and `3IYYwdp7` deleted the machinery, so the skill now
instructs sessions to rely on a gate that no longer exists.

## Evidence

`3IYYwdp7` has LANDED (board branch, commit `2d05d019`, accepted
2026-08-28): `flow.built_by` and every consumer are gone. Measured
2026-08-29 against `main` at `29011923`, worktree of `origin/main`.

**The machinery, run rather than read.** On the `board` branch:

```
grep -rn 'built_by' _work/ cmd/        # → no matches
bin/cosmic --make test _work/action_test.tl _work/gitverdict_test.tl \
  _work/gitreview_test.tl              # → test: PASS (3 files)
```

Those three passing files pin what is now true:

- `_work/action_test.tl:386 test_reviewable_offers_a_past_builder` —
  `next` offers the verdict on an item to the session that built it,
  to the session holding its claim, and to a stranger, alike.
  `_work/action.tl:187 reviewable` steps over exactly one thing: an
  item under ANOTHER session's live review claim.
- `_work/gitreview_test.tl:78 test_unnamed_sessions_and_other_phases_are_refused`
  — `gitboard review` still refuses an UNNAMED session, because a
  claim names its holder. That refusal is about the claim, not about
  who built the work.
- `_work/gitverdict_test.tl:129` (inside
  `test_verdict_subject_names_the_reviewer`) — "an unnamed verdict is
  still allowed, and says nothing rather than claiming an empty
  reviewer". `gitboard verdict` refuses NO session on identity
  grounds; the session name only decides whether the commit subject
  carries a `by <name>` clause.

Consequence for the two naming paragraphs: a review subagent that does
not export `GITBOARD_SESSION` does not fail — it DERIVES the spawning
session's id, and its verdict is recorded under the builder's name, so
the log reads as a builder accepting its own build. That mis-recording,
not a refusal, is what the naming rule now prevents.

**The six stale passages.** Each command below was run from the repo
root at `29011923`:

| site | command | today |
|------|---------|-------|
| `SKILL.md` "what IS still split" | `grep -c 'never hands a session a verdict' skills/work/SKILL.md` | `1` |
| same paragraph, its conclusion | `grep -c 'a property of the board' skills/work/SKILL.md` | `1` |
| `SKILL.md` phases table, `check` row | `grep -c 'a verdict from a session that did not build it' skills/work/SKILL.md` | `1` |
| `SKILL.md` "do not invent that name" | `grep -c 'unreviewable by the next run' skills/work/SKILL.md` | `1` |
| `SKILL.md` session loop step 6 | `grep -c 'will route it elsewhere' skills/work/SKILL.md` | `1` |
| `review.md` naming paragraph | `grep -c 'both REFUSE a session its own build' skills/work/review.md` | `1` |
| `review.md` "claim before you read" | `grep -c 'non-builder' skills/work/review.md` | `1` |
| `loop.md` "`next` withholds that item" + its `never blocked` row | `grep -c 'withholds' skills/work/loop.md` | `2` |
| `loop.md` audit-record paragraph | `grep -c 'refuse it' skills/work/loop.md` | `1` |

`parallel.md`, `decompose.md` and `enable.md` carry none of it:

```
grep -rniE 'did not build|own build|the builder is remembered|route it elsewhere|non-builder|unreviewable|property of the board' skills/work/
```

returns hits only in the three files above. `SKILL.md:247` ("the
session identity … withholds work another session claimed") is TRUE
and out of scope: `_work/action.tl`'s `pullables` compares
`i.claim ~= session`, so a claim by another session is still skipped.

## Change

`skills/work/{SKILL.md,review.md,loop.md}`, prose only. Each passage
keeps what it says about CLAIMS and about the review procedure, and
drops what it says about the board machinery withholding or refusing a
verdict on identity grounds.

**`SKILL.md`, four sites.**

1. The "what IS still split" paragraph (≈L33-38) loses the
   ``next --session NAME`` sentence and its "a property of the board"
   conclusion. It says instead that the verdict is recorded by a
   review subagent whose context window never held the build, and
   that the distance is a property of the REVIEWER'S CONTEXT rather
   than of which model is running.
2. The phases table's `check` row (L198) drops "from a session that
   did not build it" and reads `awaiting a verdict from a review that
   did not hold the build`.
3. The "do not invent that name" paragraph (≈L253-257) keeps its
   claims half and drops the unreviewable consequence: a run that
   reuses a name reads the earlier run's claims as its OWN, so the
   mutual exclusion stops holding. Nothing about reviewability.
4. Session-loop step 6 (≈L385-388) keeps `never accept your own`
   VERBATIM as the rule and loses "so `next` will route it elsewhere
   and hand you something else". It says instead that `next` offers
   this verdict like any other and that the review procedure
   (`review.md`) is what holds the distance.

**`review.md`, two sites.**

5. The naming paragraph (≈L25-32) swaps the refusal for the
   mis-recording: a reviewer that names nothing derives the BUILDER's
   identity, nothing refuses that verdict, and it is recorded under
   the builder's name. The instruction (`export
   GITBOARD_SESSION=review-<ID>-<unique>`) and the audit-trail reason
   are unchanged; only the failure mode moves.
6. "claim before you read" (≈L47-48) — `any non-builder's verdict
   stands and consumes it` becomes `any verdict stands and consumes
   it`.

**`loop.md`, three sites.**

7. The `**`next` withholds that item.**` paragraph (≈L74-80) is
   replaced by one saying `next` OFFERS that item: nothing is stepped
   over for having been built here, so this session's own wave comes
   back like any other item in `check`, and the review subagent is
   spawned on it either way. Step 3 already reads "the id step 1
   reconciled there, or what `next` offers" and needs no edit.
8. The audit-record paragraph (≈L88-95) keeps the claim/`builders`
   sentence and the log-is-the-evidence sentence, and replaces "and
   both `review` and `verdict` refuse it" with the recorded
   consequence — the verdict lands under this session's own name and
   the log reads as a builder accepting its own build.
9. The `never blocked` table row `| `next` offers no review while
   your own wave sits in `check` | …withholds… |` (L113) is DELETED:
   the stall it answers cannot occur now that `next` offers the item.

The rewritten `## minted identities and your own wave` heading, its
rule ("an orchestrator may take the verdict on its own wave"), its
brief paragraph and its minted-claim paragraph stay verbatim.

## Non-goals

- No change to `_work/**` or to the `board` branch; the machinery's
  own stale comments and `gitboard --help` strings are `3IZaO4Vj`.
- Do not weaken `parallel.md`'s `N agents reviewing N PRs`
  prohibition, or touch `parallel.md`, `decompose.md`, `enable.md`.
- Do not change `SKILL.md`'s hard rule that no session accepts its own
  work. That rule is correct and stays; only claims about the BOARD
  MACHINERY enforcing it are stale.
- Do not relax the review-isolation rule `3IYiZ9Md` installed, and do
  not reintroduce an identity check under another name.
- Do not remove `builders` or any prose describing it as the audit
  record of who held a claim.
- Do not change the three verdicts, the six review checks, or the
  verdict grammar.

## Acceptance

Run from the repo root. Every "today" is measured 2026-08-29 at
`29011923`, where this item starts.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c 'never hands a session a verdict' skills/work/SKILL.md`
  prints `0` (`1` today).
- `grep -c 'a property of the board' skills/work/SKILL.md` prints `0`
  (`1` today).
- `grep -c 'a verdict from a session that did not build it'
  skills/work/SKILL.md` prints `0` (`1` today).
- `grep -c 'unreviewable by the next run' skills/work/SKILL.md` prints
  `0` (`1` today).
- `grep -c 'will route it elsewhere' skills/work/SKILL.md` prints `0`
  (`1` today).
- `grep -c 'both REFUSE a session its own build' skills/work/review.md`
  prints `0` (`1` today).
- `grep -c 'non-builder' skills/work/review.md` prints `0` (`1` today).
- `grep -c 'withholds' skills/work/loop.md` prints `0` (`2` today —
  the paragraph and the `never blocked` row).
- `grep -c 'refuse it' skills/work/loop.md` prints `0` (`1` today).
- `grep -c 'built_by' skills/work/loop.md` prints `0` (`0` today —
  a guard against reintroduction, not a removal).

Each `→ 0` phrase above occurs at exactly one line today except
`withholds`, which occurs at two, and each is unique to the passage
being rewritten within its own file — no unrelated line in the same
file carries the substring, so every target is reachable. `withholds`
also occurs once in `SKILL.md:247`, where it is TRUE; that bullet is
scoped to `loop.md` and does not touch it.

Four guards that the surviving prose survived:

- `grep -c 'never accept your own' skills/work/SKILL.md` prints `1`
  (`1` today).
- `grep -c 'an orchestrator may take the verdict on its own wave'
  skills/work/loop.md` prints `1` (`1` today).
- `grep -c 'builders' skills/work/loop.md` prints `1` (`2` today — the
  deleted `next` paragraph carries one, the surviving audit-record
  sentence the other).
- `grep -c 'N agents reviewing N PRs' skills/work/parallel.md` prints
  `1` (`1` today).

Scope:

- `git diff --name-only origin/main` lists only paths under
  `skills/work/` (`0` files today).

Each `grep -c` matches a phrase that sits on one line today; a rewrite
that reflows the paragraph can make a count pass for the wrong reason,
so read the file rather than trusting the count alone.

## Enablement

`none needed` — the one blocker, `3IYYwdp7`, was accepted and
completed on 2026-08-28 (board commit `2d05d019`), which is what makes
this item's replacement prose true rather than premature.
