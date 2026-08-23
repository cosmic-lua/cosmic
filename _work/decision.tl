--- The shape a next-action decision takes. Both halves of the
--- ordering return one — `_work.intake` decides the upstream rungs
--- and `_work.action` the phased ones — so the record lives below
--- both rather than in either, and neither has to require the other
--- to name what it returns.
local item = require("_work.item")

local type Item = item.Item

--- Every kind an action takes, in the order the two halves choose
--- between them: rightmost phase first, then the upstream rungs,
--- then the stall.
---
--- Data rather than a doc comment because things key off a kind —
--- `_work.guidance`, which says what each one MEANS — and a list
--- copied beside this one drifts from it. Whatever keys off kinds is
--- checked against this table, so a kind added to the ordering is a
--- kind those tables are made to answer for.
local KINDS < const >: {string} = {
  "finish", "review", "pull", "unblock", "refine", "promote", "sweep",
  "triage", "intake", "none",
}

--- One decided action: what to do, to what, and under which rule.
local record Action
  --- One of `KINDS`.
  kind: string
  --- The item the action targets; nil for intake-with-no-root and none.
  item: Item
  --- The rule that chose this action, stated for the human/agent.
  reason: string
end

local record decision
  type Action = Action
  KINDS: {string}
end

local M: decision = {
  KINDS = KINDS,
}

return M
