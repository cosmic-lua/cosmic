--- The shape a next-action decision takes. Both halves of the
--- ordering return one — `_work.intake` decides the upstream rungs
--- and `_work.action` the phased ones — so the record lives below
--- both rather than in either, and neither has to require the other
--- to name what it returns.
local item = require("_work.item")

local type Item = item.Item

--- One decided action: what to do, to what, and under which rule.
local record Action
  --- "review" | "refine" | "promote" | "sweep" | "triage" | "intake"
  --- | "finish" | "pull" | "unblock" | "none"
  kind: string
  --- The item the action targets; nil for intake-with-no-root and none.
  item: Item
  --- The rule that chose this action, stated for the human/agent.
  reason: string
end

local record decision
  type Action = Action
end

local M: decision = {}

return M
