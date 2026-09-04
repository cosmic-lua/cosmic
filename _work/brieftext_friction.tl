--- The friction-collection paragraph every brief appends after its own
--- "Final report" section: what `skills/work/friction.md`'s "what the
--- agent reports" block asks an orchestrator to hand a subagent,
--- carried here so `_work.brief` appends it itself rather than
--- trusting a human to append it by hand. Appended unconditionally to
--- every kind: a pass not collecting friction ignores the section at
--- no cost, and one that is never has to remember it.
---
--- Pure data, split out so `_work.brieftext`'s own template split
--- stays untouched.

local ASK < const > = [[
Friction: end your final report with a `## Friction` section of at
most five entries. Each entry names the goal you had at that point,
what actually happened instead (with how long it took and how many
tool calls it cost, as best you can tell), what in the spec, brief,
tree, tool, or environment made the difference, and what would have
prevented it. Report where the spec or brief was unclear, where a
tool refused or misled you, where you rediscovered something the
tree documents, and any work you did and then threw away. An empty
section is a real answer; never pad it.]]

local record brieftext_friction
  ASK: string
end

local M: brieftext_friction = {
  ASK = ASK,
}

return M
