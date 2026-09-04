## Evidence

Of the two `friction:` logs filed on 2026-09-04, one carried a section
per spawned agent (18 agents, read with the transcript reader) and the
other carried none: its orchestrator never ran the reader and said so
in the log's closing note. Nothing refused the thinner log; the only
thing that distinguishes the two is prose. Once minted labels carry
the orchestrator (`<kind>-<handle>-<orch8>`, the label item this one
waits on), the board log itself says which agents a given orchestrator
claimed for: every `take` commit whose session label ends in that
orchestrator's `<orch8>`.

## Change

`_work/gitgraph.tl`, `new`: when the title starts with `friction:`,
collect the labels of every claim this session's `<orch8>` minted
since the pass began (the earliest such `take` in the board log newer
than the previous `friction:` item this orchestrator filed, or all of
them on a first pass), and require the spec to contain a heading `##
<kind> <handle>` for each; refuse with `REFUSED: friction log names 3
of 9 agents — missing review djEO_SQWp, build fU6l_yGKY, ...` and the
exact `cosmic _tool/friction.tl <transcript>` invocation shape the
chapter gives. `--force --why` files it anyway (a pass whose
transcripts are gone). Titles not starting with `friction:` are
unaffected.

`_work/gitgraph_test.tl`: a board with three minted claims and a log
naming two refuses; naming three passes; `--force` passes.

## Non-goals

The tool never reads a transcript; it checks the log against the
board.
