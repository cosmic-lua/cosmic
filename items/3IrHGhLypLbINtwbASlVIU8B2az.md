## Evidence

Two `/work N --routine` passes in a row opened the friction log after
several board verbs instead of before the first one, violating
`skills/work/friction.md`'s own step 1 ("open the log before the first
board verb"). «FcWz_FClp» (friction: 2026-09-04 work9) records this
exact miss: `sync`, `next`, `show`, and a `take` ran before the log
existed. This pass (2026-09-04, a later `/work 9 --routine` run)
repeated it independently: `sync`, `show`, `next`, and three `take`
calls ran before `friction-2026-09-04-work9.md` was created.

`skills/work/SKILL.md`'s `--routine` section lists the friction-log
steps (open the log, append the ask, write agent sections from
`_tool/friction.tl`, close the pass) but the "open it first" ordering
constraint lives only in `skills/work/friction.md`'s "the log" section,
a file the orchestrator does not re-read every pass — it is read once
while orienting, then not consulted again mid-pass. The rule is
correct where it lives; it just is not restated where the loop's step
order is enumerated, which is the one place a session under time
pressure actually looks.

## Change

`skills/work/SKILL.md`, in the `--routine` section's friction-log
bullet list (the "the friction log" paragraph, step 1: "open the log
before the first board verb"): no wording change — the sentence
already says this. Add one clause making the ordering constraint
concrete and self-checking: name the exact first verbs a bootstrap
pass runs (`sync`, then `show`/`next`) and state that the friction log
file must exist on disk before the first of `next`, `take`, `attach`,
or `compare` — i.e. `sync` and a plain `show` (board-wide, no ID) are
the only verbs allowed before the log file is created, since bootstrap
and sync produce no board state to log yet.

## Non-goals

Not a tool-level gate — `skills/work/friction.md` already states the
rule in prose; this is the doc restating it at the point of use, per
`skills/work/friction.md`'s own leverage ranking ("a doc over a skill
sentence" — this literally is the skill-sentence tier, chosen because
the countermeasure is text-only and the rule already exists elsewhere
in the tree). No change to `_work/*.tl` or to `gitboard`'s own verbs.
