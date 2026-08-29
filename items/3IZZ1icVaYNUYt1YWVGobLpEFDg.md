## Goal

G8 — the flow system. Give the handover to `check` a third form that
names a COMMIT, so a slice whose work lands by direct push to `board`
can hand a reviewer something reviewable without borrowing a section
meant for findings.

The handover model today has exactly two kinds, and both are about
where the reviewable thing lives:

- **PR-carried** — `--pr N`. The reviewer follows `it.pr` to a diff on
  GitHub, and `land` reads the same field back to confirm the merge.
- **findings-carried** — `--evidence`. There is no diff; the
  deliverable IS the recorded measurement, and the reviewer reads the
  spec's `## Result` section to judge whether the numbers are sound and
  the follow-ups are the right ones.

Board-branch code is neither. It is a real code change with a real
diff, but it lands by direct push to `board` — there is no pull request
and there never will be one — so the only door open to it is the
findings door. That is a category error: `## Result` then holds a
pointer to a commit range rather than findings, and both the reviewer
and any later reader of the board have to work out which of the two
things a given `## Result` actually is.

## Evidence

Hit live on **`3IYYwdp7`** ("the review guard keys on claim-holding,
not authorship") on 2026-08-29. Its work landed on `board` as
`db981771e5bdc7fb8e10f14e1a909a94815b293c` (parent `5e697c27`), gated
by the `board` workflow — run `33230984580`, conclusion `success` —
and locally by `bin/cosmic --make ci` ending `ci: PASS (4 stages)`.
There was no PR, because board-branch code does not get one.

`gitboard move 3IYYwdp7 check` refused twice, verbatim:

```
REFUSED: a handover to check names its PR — pass --pr N, or --evidence to hand over recorded findings
```

```
REFUSED: an evidence handover carries its findings — 3IYYwdp7's spec has no ## Result section
```

Both refusals are correct as written. Neither has a form that fits.

**Where it lives.** `cmd_move` in `_work/gitverbs.tl:121`. The gate is
the block at `:174-186`, which fires when the target is `check`, no PR
number is in hand from either the flag or the item, and `--force` was
not passed:

- `:174` — `if target == "check" and (pr or 0) == 0 and (it.pr or 0) == 0 and not force then`
- `:175-179` — the first refusal, when `--evidence` was not passed
- `:180-185` — the second, when it was: `if not has_result(s, id) then`

`has_result` is the private helper at `_work/gitverbs.tl:109`. It asks
`spec.section_of(store.read_spec(s, id), "Result")` for the section and
returns true only when a non-blank line sits under the heading. Its own
doc comment says what it is for — "Whether an item's spec sidecar
carries a `## Result` section with content under it" — and the comment
above the gate at `:159-173` states the intent plainly: an evidence
handover is for "a research slice" whose "deliverable is recorded
findings and the follow-up items they seed". A landed commit is not
that.

**The workaround this session took, recorded rather than hidden.**
`3IYYwdp7` was handed over with `--evidence` after a `## Result`
section was appended to its spec that carries the commit sha, its
parent, the `git diff 5e697c27..db981771` invocation, the CI run and
the re-measured acceptance table. It reads as a pointer to a diff
inside a section the tool documents as findings, and it says so in its
own first paragraph. That item is in `check` on those terms; this item
exists so the next one does not have to do the same thing.

**Why it is structural and not a one-off.** Everything under `_work/`,
`items/` and the board's own machinery lands this way — `board.yml`
gates the direct push, exactly as `pr.yml` gates a PR. Every future
board-machinery slice hits this gate. `3IYYwdp7` is the first one to
hit it after `--evidence` existed, which is why it surfaced now.

## Change

Sketch, not a settled design — the shape to aim at is a third handover
that records a sha on the item the way `--pr` records a number.

**A `--commit SHA` flag on `move`.** It sits beside `--pr N` and
`--evidence` in `cmd_move`'s signature and in `gitboard help move`, and
it satisfies the same `target == "check"` bar the other two do. The
gate at `_work/gitverbs.tl:174` grows a third arm, and its first
refusal line grows a third clause naming it.

**An item field to record it.** `item.Item` carries `pr: integer`
(`_work/item.tl:69`, parsed at `:230`); the parallel is a `commit:
string`, written by the same path that writes `it.pr` at
`_work/gitverbs.tl:254` and by `gitgate.set_in_place`
(`_work/gitgate.tl:288-290`). `gitview.tl:80` renders `pr:%d` in the board
marks and would render the short sha the same way.

**What the reviewer is pointed at.** A sha alone is enough to find the
diff only if the base is known; recording the parent, or accepting a
`BASE..HEAD` range, is the open question. Resolving it against the
local repo at handover time — the commit must exist and be an ancestor
of the branch tip — is the analogue of the accept-time PR-state read
and is worth considering, but is a decision this item has to make, not
one it inherits.

**The landing half.** `land` reads `it.pr` and asks GitHub whether the
PR merged (`_work/gitland.tl:53-77`); `gitverdict.tl:194` already ends
a PR-less item on accept rather than parking it in `land`. A
commit-carrying item is closer to the second — the commit is already
on `board` at handover time, so there is nothing left to wait for —
but which of the two paths it takes is part of this item's decision.

## Non-goals

- **Do not weaken the requirement that arrival in `check` names
  something reviewable.** That is the point of the gate and it is
  correct. The fix is a third way to name something, never a way to
  name nothing. A bare `move ID check` with no PR, no evidence and no
  commit must still be refused.
- **Do not touch the PR path.** `--pr N`, `it.pr`, the accept-time
  PR-state read in `gitverdict.tl:147-148`, `gitgate.handover_refusal`
  and everything in `gitland.tl` behave exactly as they do today.
- **Do not touch the evidence path.** `--evidence`, `has_result`, and
  `spec.section_of`'s `## Result` lookup keep their current meaning:
  findings, judged as findings. This item narrows what `## Result` is
  asked to carry; it does not change how the evidence handover works
  for the research slices it was built for.
- Do not repurpose `--force`. Forcing past the gate is repair, not a
  handover form.
- Do not change the phase rules, the WIP limits, the three verdicts, or
  any verdict-line format beyond the one refusal line that must name
  the new flag.
- Do not retroactively rewrite `3IYYwdp7`'s `## Result`. It is the
  record of what was actually done, workaround included.

## Acceptance

- `gitboard help move` lists the third handover alongside `--pr` and
  `--evidence`.
- A `do` item with no PR and no `## Result` section, whose work landed
  as a commit on `board`, reaches `check` with that handover and no
  `--force`.
- The same item with no handover flag at all is still refused, and the
  refusal names all three forms.
- The commit is recorded on the item and readable back from `gitboard
  show`, the way `pr` is today.
- An evidence handover on a research slice is byte-identical in
  behaviour to today: `--evidence` with a `## Result` section passes,
  `--evidence` without one is refused with the unchanged second
  refusal line.
- A PR handover is unchanged: `--pr N` passes and `land` still reads
  the number back.
- `bin/cosmic --make ci` ends `ci: PASS` from the `board` worktree.
- A test asserts each of the three handover forms and the no-form
  refusal, in `_work/gitverbs_test.tl` where the store fixture lives.

## Enablement

Nothing blocks it. `3IYYwdp7` sits in `check` having taken the
workaround, so this item can be specified from the refusal transcript
above without waiting on that verdict. It needs a decision on two open
questions before it is ready: how the diff base is named alongside the
sha, and whether a commit-carrying item ends on accept or passes
through `land`.

## Result

Closed 2026-08-29, overtaken by practice: board-branch machinery work is PR-carried now — this session alone landed nine reviewed PRs against base `board` (1515-1517, 1520-1521, 1523, 1525-1529 span), each through the standard take --pr handover, fresh-context review, and verdict. The third handover form (commit-naming) is unnecessary because the norm it would serve — direct push of reviewable code to board — is no longer how machinery changes land; mutations (state) remain direct-push by design and are not review objects.
