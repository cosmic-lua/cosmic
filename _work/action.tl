--- The one answer to "what should I do now": a pure function from the
--- item list to a single action. The graph rules it reads are
--- `_work.flow`; this module is only the decision, split out so the
--- rules module is not also the policy that consults them.
---
--- There is ONE worker and one ordering. Work flows right to left —
--- whatever is closest to completion moves first, because finishing
--- beats starting — so an accepted PR is merged before a verdict is
--- written, a verdict before work is finished, finishing before
--- pulling, and only then does anything new enter: drain a triage
--- queue past its bound, refine toward the bar while `ready` has
--- somewhere to put the result, triage what is left, and take in new
--- work last. An inbox nobody empties is a channel that only takes,
--- which is why the bound jumps its queue ahead of refinement.
---
--- Doing SEVERAL actions is running this again after each one. The
--- board moved, so the answer may have moved with it: nothing here
--- plans a batch, and a caller that wants five actions asks five
--- times.
---
--- Every queue this reads is PRIORITY order with age as the last
--- word (`_work.priority`), so "the next ready item" is really "the
--- most important one, oldest among equals".
---
--- A claim is a LOCK, and this is where that means something twice
--- over. `do` holds five because five sessions run at once, so a
--- session that names itself is never handed work another session
--- claimed. The claim survives the move into `check`, so it also
--- names who BUILT the thing awaiting a verdict — and this hands that
--- item to somebody else, because a review is worth what the distance
--- between builder and reviewer is worth. Neither skip applies to a
--- session that names nothing: it has nobody to collide with and no
--- distance to keep, and sees every claim rendered in the reason
--- instead.
local flow = require("_work.flow")
local item = require("_work.item")
local prio = require("_work.priority")

local type Item = item.Item

--- One decided action: what to do, to what, and under which rule.
local record Action
  --- "review" | "refine" | "triage" | "intake" | "finish" | "pull" | "none"
  kind: string
  --- The item the action targets; nil for intake-with-no-root and none.
  item: Item
  --- The rule that chose this action, stated for the human/agent.
  reason: string
end

--- The first item of a phase this session may take, and how many it
--- stepped over because another session holds them. An unclaimed item
--- is anyone's; a session's own claim is its own; with no session
--- named nothing is held.
--- @param b flow.Board The board
--- @param phase string The phase to draw from
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @return Item | nil The item to act on
--- @return integer How many held items were skipped
local function unheld(b: flow.Board, phase: string, session: string,
    pos: {string: prio.Position}): Item | nil, integer
  local first: Item = nil
  local held = 0
  for _, i in ipairs(flow.queued(b, phase, pos)) do
    if (i.claim or "") ~= "" and session ~= "" and i.claim ~= session then
      held = held + 1
    elseif first == nil then
      first = i
    end
  end
  return first, held
end

--- The first item awaiting a verdict that this session did not build,
--- and how many it stepped over as its own. The inverse of `unheld`:
--- there, another session's claim is what disqualifies an item; here
--- it is the only thing that qualifies one.
--- @param b flow.Board The board
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @return Item | nil The item to review
--- @return integer How many of this session's own were skipped
local function reviewable(b: flow.Board, session: string,
    pos: {string: prio.Position}): Item | nil, integer
  local first: Item = nil
  local mine = 0
  for _, i in ipairs(flow.queued(b, "check", pos)) do
    if session ~= "" and (i.claim or "") == session then
      mine = mine + 1
    elseif first == nil then
      first = i
    end
  end
  return first, mine
end

--- The first ready item this session may pull: no open blocker, and
--- not held by another session.
--- @param b flow.Board The board
--- @param index flow.Index Items by id
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @return Item | nil The pullable item
local function first_pullable(b: flow.Board, index: flow.Index,
    session: string, pos: {string: prio.Position}): Item | nil
  for _, i in ipairs(flow.queued(b, "ready", pos)) do
    local held = (i.claim or "") ~= "" and session ~= "" and i.claim ~= session
    if not held and not flow.is_blocked(i, index) then
      return i
    end
  end
  return nil
end

--- What the phased half of the ordering decided, and what it stepped
--- over on the way. The counts ride on the record rather than in
--- further return slots: an absent `action` is the interesting case,
--- and a caller cannot read past slot two.
local record Phased
  --- The decision, absent when the board holds nothing this session
  --- may move.
  action: Action
  --- Items held by other sessions.
  held: integer
  --- Items in `check` this session built.
  mine: integer
end

--- The phased half of the ordering: land, review, finish, pull.
--- @param b flow.Board The board
--- @param index flow.Index Items by id
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @return Phased The decision and what it stepped over
local function phased_action(b: flow.Board, index: flow.Index, session: string,
    pos: {string: prio.Position}): Phased
  local landing = flow.queued(b, "land", pos)
  if #landing > 0 then
    return {action = {
        kind = "finish",
        item = landing[1],
        reason = ("land holds %d/%d — %s is accepted, awaiting merge"):format(
          #landing, flow.LIMITS["land"], landing[1].id:sub(1, 8)),
      }, held = 0, mine = 0}
  end
  local judging, mine = reviewable(b, session, pos)
  if judging then
    return {action = {
        kind = "review",
        item = judging,
        reason = "check is the rightmost phase awaiting a decision — "
        .. "verdicts before new work",
      }, held = 0, mine = mine}
  end
  local doing, held = unheld(b, "do", session, pos)
  if doing then
    local whose = ""
    if (doing.claim or "") ~= "" then
      whose = (" (claimed by %s)"):format(doing.claim)
    end
    return {action = {
        kind = "finish",
        item = doing,
        reason = ("do holds %d/%d — finish before pulling%s"):format(
          #(b["do"] or {}), flow.LIMITS["do"], whose),
      }, held = held, mine = mine}
  end
  local pullable = first_pullable(b, index, session, pos)
  if pullable then
    return {action = {
        kind = "pull",
        item = pullable,
        reason = "highest-priority ready item with no open blocker",
      }, held = held, mine = mine}
  end
  return {held = held, mine = mine}
end

--- The intake half: drain a triage queue past its bound, refine
--- toward the bar while `ready` has room, triage what remains, then
--- decompose the highest-placed root nothing drives.
--- @param items {Item} All items
--- @param b flow.Board The board
--- @param pos {string: prio.Position} Position by item id
--- @return Action | nil The decision
local function intake_action(items: {Item}, b: flow.Board,
    pos: {string: prio.Position}): Action | nil
  local triage = flow.untriaged(items)
  if #triage > flow.TRIAGE_LIMIT then
    return {
      kind = "triage",
      item = triage[1],
      reason = ("%d item(s) awaiting triage, over the bound of %d — "
        .. "draining outranks refining"):format(#triage, flow.TRIAGE_LIMIT),
    }
  end
  local planning = flow.queued(b, "plan", pos)
  if #planning > 0 and #(b["ready"] or {}) < flow.LIMITS["ready"] then
    return {
      kind = "refine",
      item = planning[1],
      reason = ("ready holds %d/%d — refine a plan item toward the bar")
      :format(#(b["ready"] or {}), flow.LIMITS["ready"]),
    }
  end
  if #triage > 0 then
    return {
      kind = "triage",
      item = triage[1],
      reason = ("%d item(s) await triage — attach it under something "
        .. "placed, compare it, or close it"):format(#triage),
    }
  end
  if #(b["plan"] or {}) < flow.LIMITS["plan"] then
    local ordered, live = flow.roots(items)
    for _, g in ipairs(ordered) do
      if not live[g.id] then
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
  end
  return nil
end

--- The one action to take now, right to left.
--- @param items {Item} All items
--- @param session string This session's name, "" when unnamed
--- @return Action The decision
local function next_action(items: {Item}, session?: string): Action
  local who = session or ""
  local b = flow.board(items)
  local index = flow.by_id(items)
  local pos = prio.positions(items)
  local ph = phased_action(b, index, who, pos)
  local phased = ph.action
  if phased then
    return phased
  end
  local taking = intake_action(items, b, pos)
  if taking then
    return taking
  end
  if ph.mine > 0 then
    return {
      kind = "none",
      reason = ("%d item(s) in check were built by this session — another "
        .. "session reviews them"):format(ph.mine),
    }
  end
  if ph.held > 0 then
    return {
      kind = "none",
      reason = ("%d do item(s) are claimed by other sessions and nothing "
        .. "is ready to pull"):format(ph.held),
    }
  end
  return {
    kind = "none",
    reason = "plan and ready are at limit with nothing to check — "
    .. "implementation has to catch up before planning adds more",
  }
end

local record action
  type Action = Action
  type Phased = Phased
  unheld: function(b: flow.Board, phase: string, session: string,
  pos: {string: prio.Position}): Item | nil, integer
  reviewable: function(b: flow.Board, session: string,
  pos: {string: prio.Position}): Item | nil, integer
  first_pullable: function(b: flow.Board, index: flow.Index, session: string,
  pos: {string: prio.Position}): Item | nil
  next_action: function(items: {Item}, session?: string): Action
end

local M: action = {
  unheld = unheld,
  reviewable = reviewable,
  first_pullable = first_pullable,
  next_action = next_action,
}

return M
