## Evidence

Two `/work 9 --routine` passes ran on 2026-09-04. The second's own
friction log records that none of its 13 spawned agents (7 build or
research, 6 review) received the friction paragraph
`skills/work/friction.md` ("what the agent reports") asks the
orchestrator to append, so its per-agent sections are absent
entirely; the first pass appended it by hand. The paragraph rides
after the brief as an environment note today, the same channel as the
worktree path, which is exactly the channel an orchestrator forgets.
`gitboard brief` already carries every standing rule the agent needs
(`_work/brieftext.tl`, 497 lines: the `Board:` line, the capture
rule, the bounce rule) and a `--dir`-filled path; nothing in it asks
for friction.

## Change

`_work/brieftext.tl` — after the split the builder-brief item performs
(this item waits on it), so the file has room — every brief kind
(builder, research, review, refine, decompose) ends its "Final report"
section with one paragraph, verbatim from `skills/work/friction.md`'s
"what the agent reports" block: a `## Friction` section of at most
five entries, each with the goal, what happened instead with how long
and how many tool calls, what made the difference, and what would
have prevented it; an empty section is a real answer. The paragraph
is unconditional: a pass that is not collecting friction ignores the
section at no cost, and one that is never has to remember it.

`_work/brief_test.tl`: one `find` per kind pins the paragraph's first
sentence.

## Non-goals

No change to the orchestrator-side procedure in `friction.md` beyond
deleting the sentence that says to append the paragraph by hand.
