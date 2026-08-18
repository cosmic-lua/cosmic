## Goal

G8 — the flow system (docs/goals.md): "the measurement is currently UNBUILT for
the file-based board: every transition is a commit on the `board` branch, so
`git log` holds the flow record, but nothing reads it yet — the label-era `stats`
tool measured GitHub timelines, which no longer carry the board." This item
replaces 3I0L1TbU (ended not-planned: its target, the label-era `_work/stats.tl`
GitHub-issue-timeline tool, was deleted from every branch by #1257, the same
commit series that finished the board's migration onto git-backed state).

## Change (not yet refined — this is intake, not a ready spec)

Build the flow-health instrument G8 names, reading the `board` branch's own git
log instead of GitHub issue timelines: for each `items/<ksuid>.tl` a phase move
is one commit (see `_work/gitverbs.tl` on the `board` branch and its commit
messages, e.g. "move ID PHASE -> PHASE"), so the flow record is `git log
--follow` (or a full-history walk) over `items/**` on `board`, not an API call.
The report should recover what the old `_work/stats.tl` measured (dwell time per
phase, WIP-limit adherence over time, bounce/rework/accept counts, pickup
latency) from that commit history instead. This item needs a planner refinement
pass (decompose.md) before it is ready-bar-eligible: at minimum it needs to
settle where the new tool lives (probably `_work/stats.tl` on the `board`
branch itself, beside `gitview.tl`/`gitverbs.tl`, since that is where the git
log it reads lives), what its window/`--days` semantics are, and whether it
needs a new `gitboard` verb or is a standalone script.

## Non-goals

- Not a rescue of 3I0L1TbU's diff — that spec's line-level instructions (call
  sites, facts block) are for files that no longer exist.
- Not settled here: this card itself still needs refinement before an
  implementer can pull it.
