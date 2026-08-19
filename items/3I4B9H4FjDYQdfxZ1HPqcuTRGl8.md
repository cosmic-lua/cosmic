## Goal

G8 — the flow system: a constraint a spec imposes must be checkable by a
command, or the review is the only gate and PR #1264 happens again (two
of five new files 14–73% over the spec's own 200-line cap, four green CI
runs, unnoticed until review).

## Evidence

PR #1264 (item 3HyCSe5U): the spec's `Change` stated a 200-line per-file
cap in prose; `--make lint` enforces only the blanket 500-line cap; the
PR body's size claim answered the 500 question, not the 200 one; no gate
sat between. The gap is general: a numeric bound stated in `Change`
prose is invisible to every mechanism the flow has — the acceptance-
quoting convention, the reviewer's checklist, and CI all key on
`Acceptance` commands.

## Change

The countermeasure is the docs rung, and the spec grammar stays out of
prose-parsing — measured reason recorded below. One file,
`skills/work/decompose.md` (204 lines, 296 of headroom;
`.claude/skills` is a symlink to `skills/`, so one edit):

1. In the ready-bar `## Acceptance` bullet (line 133's "anything not
   checkable by a command is not acceptance — rewrite it until it is"):
   add the corollary sentence — a numeric bound the spec IMPOSES (a
   per-file line cap, a count ceiling, a size budget) is written as an
   Acceptance command with its bound (`wc -l <file>` ≤ N, `grep -c` = N),
   never as `Change` prose; `Change` may motivate the number, but the
   Acceptance command is the contract, and a bound with no command is
   the "acceptance by vibes" anti-pattern wearing digits.
2. Same bullet, the sibling rule (folded from 3I1mysET, whose two core
   halves landed with PR #1209's merged version — `_eval/score.tl`'s
   `stage_scoring_copy` now mirrors the run dir into mkdtemp and never
   writes its input): an Acceptance command must be safe and meaningful
   to run LITERALLY, verbatim, from the repo root — it may not write
   into the committed tree, and the argument shapes it names must be
   shapes a test actually covers. #1179's acceptance failed both ways:
   its relative fixture path was the one shape the suite never tested
   (and broke), and running it verbatim wrote ten stray files into the
   committed fixture.
3. In the "two clauses to write into a slice" paragraph (line 100): make
   it "the clauses", adding both rules above where refiners already
   collect slice-writing duties.
4. In `## anti-patterns`: extend the "acceptance by vibes" entry with
   the PR #1264 instance as the named example.

Why not core (`_work/spec.tl`), recorded per enable.md's ordering:
mechanically flagging cap-like prose in `Change` was probed against the
board's own live specs on 2026-08-19 and false-positives immediately —
two same-day ready specs (3I44Et1Z, 3I3qas9t) contain "423 lines, 77 of
headroom" and "69 lines, well under cap" as measured DESCRIPTIONS with
no bound imposed and correctly no `wc -l` acceptance. Prose cannot carry
the imposed-vs-described distinction for a parser; a competent reader
applies it trivially. What IS mechanizable stays: the bound, once in
Acceptance, is a command the existing quoting convention and reviewer
read already gate.

## Non-goals

- no `_work/spec.tl` or `gitboard check` change, and no new spec
  section or structured `cap:` stanza — the rule rides the Acceptance
  grammar that already exists.
- no relitigation of the 500-line lint cap or any repo-wide size gate.
- no retroactive edits to landed specs; the rule binds refinement from
  now on.

## Acceptance

- `grep -c "wc -l" skills/work/decompose.md` prints ≥ 2 (the bullet's
  corollary and the clauses paragraph).
- `grep -c "committed tree" skills/work/decompose.md` prints ≥ 1 (the
  run-literally rule).
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — a self-contained docs edit; anchors, line numbers, and
headroom measured above; the rejected-core reasoning is recorded so the
next session does not re-probe it.
