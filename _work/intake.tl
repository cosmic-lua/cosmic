--- The intake half of the next-action ordering: everything upstream
--- of a claim. `_work.action` decides the in-flight half — land,
--- review, finish, pull — and consults this only when none of those
--- has work, so nothing here ever outranks moving something that is
--- already in flight.
---
--- The rungs, in order: triage what arrived, refine the top of todo
--- toward the spec bar, and decompose an undriven root. Triage first
--- because it is the cheap decision (is this real, and under which
--- outcome) and the starvable one — an unplaced capture is invisible
--- to every queue, and an inbox nobody empties is a channel that only
--- takes. Refinement is where the expensive judgment goes, and it can
--- never starve: the top of todo is always there.
local decision = require("_work.decision")
local flow = require("_work.flow")
local item = require("_work.item")
local prio = require("_work.priority")

local type Item = item.Item
local type Action = decision.Action
local type Specs = {string: string}

--- The highest-placed todo item worth refining: not blocked, placed,
--- and failing the spec bar. Skipping blocked items keeps refinement
--- feeding work a take can actually start; a blocked spec often moves
--- again when its blocker lands.
--- @param items {Item} All items
--- @param specs Specs Spec sidecar body, by item id
--- @param index flow.Index Items by id
--- @param pos {string: prio.Position} Position by item id
--- @return Item | nil The item to refine
local function refinable(items: {Item}, specs: Specs, index: flow.Index,
    pos: {string: prio.Position}): Item | nil
  for _, i in ipairs(flow.in_state(items, "todo", pos)) do
    if not flow.is_blocked(i, index) and prio.is_placed(pos, i.id)
    and #flow.ready_gaps(specs[i.id] or "") > 0 then
      return i
    end
  end
  return nil
end

--- The intake decision, or nil when intake has nothing to offer.
--- @param items {Item} All items
--- @param specs Specs Spec sidecar body, by item id
--- @param index flow.Index Items by id
--- @param pos {string: prio.Position} Position by item id
--- @return Action | nil The decision
local function intake_action(items: {Item}, specs: Specs, index: flow.Index,
    pos: {string: prio.Position}): Action | nil
  local triage = flow.untriaged(items)
  if #triage > 0 then
    return {
      kind = "triage",
      item = triage[1],
      reason = ("%d item(s) await triage — attach it under something "
        .. "placed, compare it, or close it"):format(#triage),
    }
  end
  local refining = refinable(items, specs, index, pos)
  if refining ~= nil then
    return {
      kind = "refine",
      item = refining,
      reason = "the highest-placed todo item that misses the spec bar — "
      .. "refine it until `check` passes",
    }
  end
  -- A held root — its win condition verified — is walked past exactly
  -- like one with live work: nothing to decompose until evidence
  -- filed under it clears the hold.
  local ordered, live, held = flow.roots(items)
  for _, g in ipairs(ordered) do
    if not live[g.id] and not held[g.id] then
      return {
        kind = "intake",
        item = g,
        reason = ("%s has no live work — decompose it"):format(
          g.id:sub(1, 8)),
      }
    end
  end
  -- Only worth saying when there ARE placed roots: with none, "every
  -- open root has live work" is vacuously true and tells a session
  -- nothing about why it has been handed no work.
  if #ordered > 0 then
    return {kind = "intake", reason = "every open root has live work — "
      .. "work backwards from the highest-placed one with slack"}
  end
  return nil
end

local record intake
  type Specs = Specs
  refinable: function(items: {Item}, specs: Specs, index: flow.Index,
  pos: {string: prio.Position}): Item | nil
  intake_action: function(items: {Item}, specs: Specs, index: flow.Index,
  pos: {string: prio.Position}): Action | nil
end

local M: intake = {
  refinable = refinable,
  intake_action = intake_action,
}

return M
