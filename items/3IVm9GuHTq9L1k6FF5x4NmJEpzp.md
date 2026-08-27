## Goal

G8 — the flow system (parent 3HyRdT1J). A session invoked as `/work N`
(typically `/loop /work 5`) runs one bounded orchestrator pass per
invocation instead of interpreting the fan-out from scratch: terse
reporting, never blocking, and the review distance held across a wave.

## Change

Two files on `main`, delivered as PR 1462 (already open and green;
this item joins it to the board for review).

**1. New `skills/work/loop.md`** — the standing-loop chapter:
- one pass, right to left: sync + reconcile the previous wave, land,
  at most ~one inline review (never fanned out), fill the wave by
  claiming first and spawning agents in the background, fall back to
  intake, then report and end — never waiting inside a pass;
- minted identities: agent claims are `<session>/<suffix>`, and the
  verdict wall — a session never judges work its own wave built;
  `built_by` cannot see the relationship yet, so the wall is prose
  here and the machinery half is 3IVJVZJt;
- a stall table mapping every refusal a loop hits to its non-blocking
  answer, with find-before-file dedupe for captures;
- the report: a one-line-per-action ledger, with `/loop` no-op
  semantics for quiet passes.

**2. `skills/work/SKILL.md`** — the chapter joins the list with a
pointer beside `parallel.md`'s, the frontmatter names the `/work N`
invocation, and the board-in-one-minute CAS paragraph now tells the
drop-and-re-run story the board branch's publish rewrite landed
(a lost race drops the mutation whole and names the re-run; a
rejection with the remote unmoved is policy and keeps the commit
local) — the follow-up that rewrite's PR promised on `main`.

## Non-goals

- No machinery change: `built_by` prefix matching (3IVJVZJt) and the
  verdict verb's builders check (3IVJUjX4) are their own items.
- No change to `parallel.md` — the loop chapter builds on it by
  reference and restates none of its mechanics.
- No new WIP limits or lease values.

## Acceptance

- `bin/cosmic --make ci` from the repo root ends `ci: PASS` (run at
  head 946badeb: `ci: PASS (5 stages)`; all five CI lanes green).
- `skills/work/loop.md` exists and SKILL.md's chapter list names it.
- SKILL.md's CAS paragraph describes drop-and-re-run, not
  rebase-and-recheck.

## Enablement

none needed — two markdown files on `main`, gated by the repo's own
`--make ci`; no blocker items. The review is prose review: does the
chapter say what the system means, and does the CAS paragraph match
the machinery that merged.
