Imported from whilp/cosmic#1202.

## Goal

G8 — the flow system, via epic #1117. `review.md`'s feedback half is what makes
the system converge: every non-accept verdict names the wrong turn and files the
countermeasure. Today nothing can tell whether it did, so the half that converges
the system is the half with no gate on it.

## Change

Make a non-accept verdict machine-checkable for its countermeasure, the same way
an accept is already machine-checkable for its first line.

**The grammar.** A `work-verdict: request changes` or `work-verdict: reject`
comment must carry, on a line of its own anywhere in the body, exactly one of:

```
enable: #1243
enable: none (the ready-bar gap was this issue's own; fixed in place)
```

`enable: #N` names the countermeasure issue. `enable: none (<why>)` is the
deliberate no-countermeasure case and requires a parenthesised reason. Nothing
else parses.

**`_work/verdict.tl`** — the pure half, mirroring `blocks_check` exactly:

1. Add `enable: string` to the `Verdict` record and to `Standing` (`:36`),
   populated by the same pass that reads the first line. Store the trailer's
   text verbatim, or `nil` when absent.
2. Add `blocks_send_back(s: Standing): string` beside `blocks_check` (`:145`),
   returning nil when the standing verdict is an accept, when no PR closes the
   issue, or when the trailer is present — and otherwise the refusal message,
   naming the PR, the verdict kind, and the two accepted trailer forms.

**`_work/verbs.tl`** — the call site, five lines, mirroring the `target ==
"check"` block at `:290`: when `target` is `do` or `plan` AND the issue is
leaving `check` AND not `--force`, call `verdict.blocks_send_back` and refuse
with `work-move: REFUSED (<message>)`.

Refusing the MOVE and not the comment is deliberate: a planner who has already
posted a verdict can post or edit a trailer in one step, so nothing is ever
stranded in `check`, and `--force` remains the repair path.

**`_work/verdict_test.tl`** — cases: trailer present with `#N`; trailer present
with `none (<why>)`; `none` without a reason REFUSED; trailer absent REFUSED;
accept with no trailer passes; no-PR passes; `--force` bypasses.

The facts this rests on, measured at `a3cd318`:

```facts
$ wc -l < _work/verbs.tl
495
$ wc -l < _work/verdict.tl
262
$ wc -l < _work/verdict_test.tl
192
$ grep -n "local function blocks_check" _work/verdict.tl
145:local function blocks_check(s: Standing): string
$ grep -n "record Standing" _work/verdict.tl
36:local record Standing
$ grep -c "enable:" _work/verdict.tl
0
```

**`_work/verbs.tl` has five lines of headroom (495/500) and the 500-line cap is
a hard gate.** That is why the predicate goes in `verdict.tl` (262 lines) and
only its call site goes in `verbs.tl`. A five-line call site fits; anything
larger does not, and growing `verbs.tl` is not in scope — if the call site
cannot be written in five lines, that is a bounce, not a refactor.

## Non-goals

No new labels and no fourth verdict. No change to the three verdicts' meanings,
to the `work-verdict:`/`plan-verdict:` first-line grammar, or to `land`'s accept
check — an accept carries no trailer and must keep passing untouched. No change
to the WIP limits, and no change to `blocks_check`'s existing rule. No refusal on
`move N check` (this gate is on the way OUT of check, not into it). Do not
enforce the trailer retroactively on verdicts already posted: the check reads the
STANDING verdict only, and `--force` covers the historical cases.

`review.md` already states the two-occurrence threshold at `:141` ("if the same
wrong turn has now appeared twice") — do NOT edit it. The original body's claim
that it needed restating from three to two is wrong.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/verdict_test.tl` ends `test: PASS (1 file)`,
  including the seven cases named above.
- `wc -l _work/verbs.tl` reports at most 500.
- `grep -c "enable:" _work/verdict.tl` returns a value greater than 0, and
  `grep -c "blocks_send_back" _work/verdict.tl _work/verbs.tl` reports both
  files non-zero — the predicate is defined in one and called from the other.

## Enablement

none needed. `blocks_check` (`_work/verdict.tl:145`) is a working precedent for
every part of this — a pure predicate returning a refusal string, called from one
guarded block in `cmd_move` — so the shape is copied, not invented. The one
capacity question (where the code can physically go) is measured in the facts
block above and decided in `Change`.

## Split off, to file when `work:plan` is under its limit

The original body carried two ready-bar rules earned in the same review round.
They are docs work with no dependency on this slice and belong in their own card,
not folded in here:

1. a `Change` that pins a file layout names every directory the tool creates and
   every path it prints, not only the ones holding deliverables (evidence:
   #1147);
2. a `Change` that moves a function names what moves WITH it — the constants and
   helpers it closes over (evidence: #1156).

Both go in `skills/work/decompose.md`'s "measured, not inferred" section beside
its two existing evidence-cited rules (`grep -c "evidence: #"` returns 2 today).


---
_Generated by [Claude Code](https://claude.ai/code)_