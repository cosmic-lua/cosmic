# Decomposing: from ambiguous goals to pullable issues

working backwards is the planner's core move: start from a goal's win
condition, find the largest gap between it and today, and keep cutting
until each piece clears the ready bar. refinement is incremental —
a goal does not decompose in one sitting, and is not supposed to; each
planner session takes the oldest shaping issue ONE rung down.

## the refinement ladder

three rungs, each with an exit test. an issue names its rung by its
labels; moving down a rung is what "refine" means.

1. **goal** — lives in [docs/goals.md](../../docs/goals.md), not on
   the board. ambitious and ambiguous by design ("no silent bugs",
   "best tool-building tool"). goals change by PR to goals.md, never
   by issue.
2. **epic** — `plan:epic` + `plan:shaping`: one outcome in service of
   a named goal, still too big or too undecided to hand over.
   *exit test:* the outcome is observable ("a fresh clone can X", "the
   eval suite scores Y") and the epic body lists its child slices as a
   checklist of issue numbers, each of which exists.
3. **slice** — `plan:shaping` without the epic marker, then
   `plan:ready` once it clears the bar: one session, one PR, one
   implementer.
   *exit test:* the ready bar below, checked by `board.tl check N` and
   the planner's own read.

decomposition mechanics on GitHub: the epic body carries a `- [ ] #N`
checklist of its slices; a slice that needs another slice first
carries a `Blocked by: #M` line (same repo only — `next` skips issues
with open blockers). when every child is closed, the planner verifies
the epic's outcome actually holds and closes the epic (`review.md`).

## ranking the outcomes: paired comparison

intake walks goals.md's ranked outcome list top-down, so the rank has
to be real — and when it is contested (a new goal enters, the context
shifts, two epics fight for capacity), the planner re-derives it with
**paired comparison** rather than argument: put each contested pair to
the goal owner, ONE question at a time —

> if cosmic could hold only one of these win conditions over the next
> several releases, which is the better cosmic?

count wins; let transitivity close the untested pairs (A > B and
B > C settles A vs C); give byes to goals that are nearly holding
(finish, don't debate) or dormant. an intransitive cycle
(A > B > C > A) is never averaged away — it means the comparison
question was ambiguous; restate what "better" means and re-run just
the cycle's pairs. AHP (Saaty) is the heavyweight variant with
weighted judgments and a consistency ratio; at a half-dozen goals the
plain tournament converges in a handful of questions and its record
is legible.

the result is committed: a re-rank is a PR to goals.md that reorders
the outcome list and records the matches in its description
([D25](../../docs/decisions/d25-outcomes-and-instruments.md)). the
committed order is the one intake reads — a ranking that lives in a
conversation is not a ranking.

## sizing a slice

a ready slice is sized for one implementer session: one PR, a diff an
implementer can hold in its head (~400 lines touched is the smell
threshold, not a rule), zero decisions left open. if writing the
`Change` section forces the word "and" between two independent
changes, cut it in two. if a slice cannot be sized without research,
the research IS the slice: a `plan:enable` issue whose deliverable is
a comment (findings) and the follow-up slices, not code.

## the ready bar

a `plan:ready` issue body carries exactly these five sections.
`board.tl check N` lints that each is present and non-empty (and
`move N ready` refuses an issue that fails the same lint); only the
planner can judge their content. the test for every sentence: **could a competent but
literal-minded implementer, with no context beyond this issue and the
repo's AGENTS.md, get this wrong?** if yes, it is not ready.

- `## Goal` — one line: the `G<n>` from goals.md this serves, or the
  parent epic (`via epic #12`). traceability, not prose.
- `## Change` — what to build, naming the files to touch and the
  shape of the change in each. imperative and concrete: "add verb X
  to `_cli/build/`, dispatching to ...", never "improve", "clean up",
  "investigate", or "support".
- `## Non-goals` — the walls: contracts that must not move, files not
  to touch, adjacent improvements not to make. this section is what
  keeps a diligent implementer from helpfully breaking something.
- `## Acceptance` — the exact commands to run and the verdict lines
  they must end with. `bin/cosmic --make ci` ending `ci: PASS` is the
  floor; add the narrow checks that prove THIS change (a specific
  test file, a fixture build, a `--docs` lookup showing the new
  entry). anything not checkable by a command is not acceptance —
  rewrite it until it is.
- `## Enablement` — the planner's record of the enablement check
  (`enable.md`): either `none needed` with a word on why, or
  `Blocked by: #N` lines pointing at the enablement issues that must
  land first.

## a worked example

```markdown
## Goal
G4 — zero-config project gates, via epic #210

## Change
Teach `--make ci` to print per-stage durations. In
`_make/verbs.tl`, wrap each stage call with `cosmic.instrument`
spans named `stage=<name>`; print one `<stage>: <secs>s` line as
each stage ends, before the existing verdict line.

## Non-goals
No new flags. No change to the `ci: PASS`/`ci: FAIL` verdict line
format — downstream scripts parse it. No timing inside stages.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS` and prints one duration
  line per stage.
- `bin/cosmic --make test _make/verbs_test.tl` passes, including
  the new `test_stage_duration_lines`.

## Enablement
none needed — `cosmic.instrument` already covers this; conventions
are in AGENTS.md.
```

## anti-patterns

- **research verbs in Change** ("investigate", "explore", "figure
  out") — that is a shaping issue or an enablement research slice,
  not ready work.
- **acceptance by vibes** ("works correctly", "is faster") — commands
  and verdict lines, or it does not go in Acceptance. for performance
  work, the `optimize` skill's gates are the acceptance.
- **hidden decisions** ("pick a reasonable format") — the planner
  picks; the issue states the pick.
- **scope by omission** — an empty Non-goals section on a change near
  a frozen contract (the `cosmo.*` C boundary, error strings, verdict
  line formats) is a planner error; name the walls.
- **decomposing to dust** — slices so small the overhead dominates
  (rename-only issues, one-liner issues in a chain). a slice earns
  its card by being independently verifiable, not by being tiny.
