Evidence (fresh-context sweep, 2026-08-30): a PR-less item can be
completed with no review at all, while the doctrine and the tool's own
guards both assume it cannot. `cmd_verdict` hard-refuses any item with
`pr == 0` (`_work/gitverdict.tl:116-119`, unconditional), and
`flow.substate` (`_work/flow.tl:64-74`) never returns "review" for a
PR-less item, so a research item can never be offered a verdict through
`next` — yet `cmd_done` (`_work/gitverbs.tl:328-352`) ends ANY item via
`done ID completed` with no review, verdict, or identity check when
`it.pr == 0`. `skills/work/SKILL.md:285` still promises "a research
item takes the same verdicts, re-running its recorded checks in place
of a diff." The two gates (spec bar, fresh-context review) hold for
diff-carrying work and silently do not exist for evidence-only work.
The fix must give research items a reviewable path (a verdict without a
PR) AND close the `done` bypass (a PR-less completion requires a
recorded accept, same distance guard), in whichever order keeps every
live flow working; decode of historical PR-less completions must stay
tolerant.
