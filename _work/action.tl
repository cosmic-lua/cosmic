--- The one answer to "what should I do now", per role: a pure
--- function from the item list to a single action. The graph rules it
--- reads are `_work.flow`; this module is only the decision, split out
--- so the rules module is not also the policy that consults them.
---
--- Both roles work right to left — whatever is closest to completion
--- moves first — because finishing beats starting: an implementer
--- lands, then finishes `do`, then pulls `ready`; a planner gives
--- verdicts, then refines, then triages, then takes in new work.
---
--- A claim is a LOCK, and this is where that means something: `do`
--- holds five because five implementer sessions run at once, so a
--- session that names itself is never handed an item another session
--- claimed. A session that names nothing skips nothing and sees every
--- claim rendered in the reason instead.
local flow = require("_work.flow")
local item = require("_work.item")

local type Item = item.Item

--- One decided action: what to do, to what, and under which rule.
local record Action
  --- "review" | "refine" | "triage" | "intake" | "finish" | "pull" | "none"
  kind: string
  --- The item the action targets; nil for intake-with-no-goal and none.
  item: Item
  --- The rule that chose this action, stated for the human/agent.
  reason: string
end

--- The oldest ready item an implementer may pull: no open blocker.
--- @param b flow.Board The board
--- @param index flow.Index Items by id
--- @return Item | nil The pullable item
local function first_pullable(b: flow.Board, index: flow.Index): Item | nil
  for _, i in ipairs(flow.oldest_first(b, "ready")) do
    if not flow.is_blocked(i, index) then
      return i
    end
  end
  return nil
end

--- The oldest `do` item this session may finish, and how many claimed
--- by other sessions it stepped over. An unclaimed item is anyone's; a
--- session's own claim is its own to finish; with no session named
--- nothing is held, because a lone session has no one to collide with.
--- @param b flow.Board The board
--- @param session string This session's name, "" when unnamed
--- @return Item | nil The item to finish
--- @return integer How many held items were skipped
local function finishable(b: flow.Board, session: string): Item | nil, integer
  local first: Item = nil
  local held = 0
  for _, i in ipairs(flow.oldest_first(b, "do")) do
    if (i.claim or "") ~= "" and session ~= "" and i.claim ~= session then
      held = held + 1
    elseif first == nil then
      first = i
    end
  end
  return first, held
end

--- The implementer's next action, right to left: land, then do, then
--- pull ready.
--- @param items {Item} All items
--- @param session string This session's name, "" when unnamed
--- @return Action The decision
local function next_for_implementer(items: {Item}, session: string): Action
  local b = flow.board(items)
  local index = flow.by_id(items)
  local landing = flow.oldest_first(b, "land")
  if #landing > 0 then
    return {
      kind = "finish",
      item = landing[1],
      reason = ("land holds %d/%d — %s is accepted, awaiting merge"):format(
        #landing, flow.LIMITS["land"], landing[1].id:sub(1, 8)),
    }
  end
  local doing, held = finishable(b, session)
  if doing then
    local whose = ""
    if (doing.claim or "") ~= "" then
      whose = (" (claimed by %s)"):format(doing.claim)
    end
    return {
      kind = "finish",
      item = doing,
      reason = ("do holds %d/%d — finish before pulling%s"):format(
        #(b["do"] or {}), flow.LIMITS["do"], whose),
    }
  end
  local pullable = first_pullable(b, index)
  if pullable then
    return {
      kind = "pull",
      item = pullable,
      reason = "oldest ready item with no open blocker",
    }
  end
  if held > 0 then
    return {
      kind = "none",
      reason = ("%d do item(s) are claimed by other sessions and nothing "
        .. "is ready to pull"):format(held),
    }
  end
  local waiting = #(b["check"] or {})
  if waiting > 0 then
    return {
      kind = "none",
      reason = ("%d item(s) await a planner verdict — that verdict is the "
        .. "bottleneck"):format(waiting),
    }
  end
  return {kind = "none", reason = "no ready work — a planner session must "
    .. "refine or intake"}
end

--- The planner's next action: verdicts first, then refine plan toward
--- ready while ready has slack, then triage findings, then intake the
--- top-ranked goal that no live work drives, else nothing.
--- @param items {Item} All items
--- @return Action The decision
local function next_for_planner(items: {Item}): Action
  local b = flow.board(items)
  local checking = flow.oldest_first(b, "check")
  if #checking > 0 then
    return {
      kind = "review",
      item = checking[1],
      reason = "check is the rightmost planner phase — verdicts first",
    }
  end
  local planning = flow.oldest_first(b, "plan")
  if #planning > 0 and #(b["ready"] or {}) < flow.LIMITS["ready"] then
    return {
      kind = "refine",
      item = planning[1],
      reason = ("ready holds %d/%d — refine a plan item toward the bar")
      :format(#(b["ready"] or {}), flow.LIMITS["ready"]),
    }
  end
  local triage = flow.findings(items)
  if #triage > 0 then
    return {
      kind = "triage",
      item = triage[1],
      reason = ("%d finding(s) await triage — attach it under a goal or "
        .. "close it"):format(#triage),
    }
  end
  if #(b["plan"] or {}) < flow.LIMITS["plan"] then
    local ranked, live = flow.goals(items)
    for _, g in ipairs(ranked) do
      if not live[g.id] then
        return {
          kind = "intake",
          item = g,
          reason = ("goal %s (rank %d) has no live work — decompose it")
          :format(g.id:sub(1, 8), g.rank),
        }
      end
    end
    return {kind = "intake", reason = "every open goal has live work — work "
      .. "backwards from the top-ranked one with slack"}
  end
  return {
    kind = "none",
    reason = "plan and ready are at limit with nothing to check — "
    .. "implementation has to catch up before planning adds more",
  }
end

--- The one action a role should take now.
--- @param items {Item} All items
--- @param role_name string "planner" or "implementer"
--- @param session string This session's name, "" when unnamed
--- @return Action | nil The decision
--- @return string Error message for an unknown role
local function for_role(items: {Item}, role_name: string, session?: string):
  Action | nil, string
  if role_name == "implementer" then
    return next_for_implementer(items, session or "")
  end
  if role_name == "planner" then
    return next_for_planner(items)
  end
  return nil, "unknown role: " .. tostring(role_name)
  .. " (expected planner or implementer)"
end

local record action
  type Action = Action
  first_pullable: function(b: flow.Board, index: flow.Index): Item | nil
  finishable: function(b: flow.Board, session: string): Item | nil, integer
  for_role: function(items: {Item}, role_name: string, session?: string):
  Action | nil, string
end

local M: action = {
  first_pullable = first_pullable,
  finishable = finishable,
  for_role = for_role,
}

return M
