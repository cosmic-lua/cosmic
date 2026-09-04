## Evidence

Measured across the `/work 9` orchestrator pass on 2026-09-04 (friction log
`friction-2026-09-04-work9.md`, filed alongside this item). `gitboard brief
review <handle>` emits a conventional, deterministic session label,
`review-<handle>-1`, for whoever reviews that item — the same string
regardless of which physical orchestrator session does the reviewing.
This repo's board is worked by multiple concurrent orchestrator sessions
(observed directly in this pass: two other items this same session filed,
«EMdb_HFX2» and «djEO_SQWp», were independently picked up, built, AND
reviewed by a different concurrent session before this session's own
review agents for the SAME items finished their work). Two review agents
in this pass ran a full adversarial review — fresh clone, rebuild, gate
run, mutation test — only to have their `gitboard verdict` call refused
at the very end because a DIFFERENT physical session, using the identical
conventional label, had already recorded a verdict first:

- review eDVe_UY1D (`a1077b93ba5b667f6`): 1513s wall, 39 tool calls,
  ~3M cache-read tokens, full independent review including a live pcall
  vs. xpcall Teal-checker probe and two separate mutation tests — refused
  at verdict time: `"3Ip8vSUa already carries an accept — land it"`.
- review djEO_SQWp (`a81aa182cdc882927`): 363s wall, 41 tool calls,
  ~3.4M cache-read tokens, full independent review including reading the
  PR's own CI logs and a local shell repro of the fix — refused at
  verdict time: `"3IqHFc4B already carries an accept — land it"`.

Both reviews reached the same conclusion as the session that beat them to
the verdict, so no decision was lost — but the full wall-clock and token
cost of each review was pure waste, entirely predictable from the label
collision alone. This is not a one-off: gitboard's own claim lock
(`take`) correctly prevents two sessions from both believing they hold a
BUILD claim (a `take` under a live label is refused, or a push race
forces a retry that then sees the live claim) — but a REVIEW claimed
under the same conventional label by two different physical sessions
both appear, locally, to have succeeded (each session's own `take`
returns success against its own view of the board before the other's
push is seen), so the mutual-exclusion property `take`'s lock is meant
to provide does not actually hold across two different physical sessions
independently reviewing the same item under the tool-generated label.

## Change

The minted session label carries the orchestrator: `<kind>-<handle>-
<orch8>`, where `<kind>` is `build`, `research`, `review`, `refine` or
`decompose` and `<orch8>` is the first 8 characters of the session id
the tool already derives (`gitboard show`'s "session: ... (from
CLAUDE_CODE_SESSION_ID)" line). `gitboard brief KIND ID` fills the
label itself — the `<REVIEW_SESSION>` placeholder goes away — and
prints it on its verdict line so the orchestrator claims under the
same string (`take ID --session <label>`). `gitboard take` on a review
(and a pull) refuses a claim whose live holder is a different label:
`REFUSED: <id> is under review by review-<handle>-<other> — take over
a live review with --force --why`; today the identical label reads as
the same session re-taking and both proceed. `help orchestrate` and
`help review` state the label shape.

`_work/brief_test.tl`: the label appears filled, with the session's
own 8 characters. `_work/gittake_test.tl`: two labels differing only
in `<orch8>` on one item — the second `take` is refused at claim time.
A self-named reviewer (solo session) keeps `review-<handle>-<unique>`
as before; the shape is what changes.

## Non-goals

Not a general redesign of the board's concurrency model — scoped to the
one place (review session labels) where two independent successful
`take`s on the same item are currently possible. Not addressing the
(much cheaper, already-tolerable) equivalent race on BUILD claims, which
this evidence did not observe causing wasted work in this pass.
