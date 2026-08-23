#!/usr/bin/env cosmic
-- The intake half of the ordering: the rungs upstream of a claim.
-- Two of them feed the pipeline where there used to be one, because
-- placing an item and committing to it are different decisions —
-- `promote` is the only way into `plan`, and `plan` is small enough
-- that taking one is a choice against everything else in `backlog`.

local check = require("cosmic.check")
local flow = require("_work.flow")
local health = require("_work.health")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local act = require("_work.action")

local counter = 0

--- A fresh deterministic id; later calls sort later, so creation
--- order is age order exactly as live ksuids behave.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

--- One valid item.
local function make(over: {string: any}): item.Item
  local t: {string: any} = {id = fresh_id(), title = "item"}
  for k, v in pairs(over or {}) do
    t[k] = v
  end
  return check.must(item.decode(t))
end

--- A board whose phased half has nothing to hand this session: `do`
--- is full of another session's claims, so no finish and no pull, and
--- `ready` is full of unblocked work, so nothing is starving.
--- @param goal item.Item The root everything hangs from
--- @return {item.Item} The items, ready to append to
local function saturated(goal: item.Item): {item.Item}
  local items: {item.Item} = {goal}
  for _ = 1, flow.LIMITS["do"] do
    items[#items + 1] = make({parent = goal.id, phase = "do",
        claim = "another-session"})
  end
  for _ = 1, flow.LIMITS["ready"] do
    items[#items + 1] = make({parent = goal.id, phase = "ready"})
  end
  return items
end

local function test_refinement_outranks_promotion()
  local goal = make({})
  local planning = make({parent = goal.id, phase = "plan"})
  local waiting = make({parent = goal.id, phase = "backlog"})
  local items: {item.Item} = {goal, planning, waiting}
  local action = act.next_action(items)
  assert(action.kind == "refine" and action.item.id == planning.id,
    "what is already committed moves before anything new is: "
    .. action.kind)
end
test_refinement_outranks_promotion()

local function test_promotion_commits_the_highest_placed_backlog_item()
  local goal = make({})
  local lesser = make({parent = goal.id, phase = "backlog"})
  local better = make({parent = goal.id, phase = "backlog",
      beats = lesser.id})
  local items: {item.Item} = {goal, lesser, better}
  local action = act.next_action(items)
  assert(action.kind == "promote" and action.item.id == better.id,
    "the queue is priority order, not age alone: " .. action.kind)
end
test_promotion_commits_the_highest_placed_backlog_item()

local function test_promotion_skips_a_blocked_backlog_item()
  local goal = make({})
  local blocker = make({parent = goal.id, phase = "backlog"})
  local blocked = make({parent = goal.id, phase = "backlog",
      beats = blocker.id, blocked_by = blocker.id})
  local items: {item.Item} = {goal, blocker, blocked}
  local action = act.next_action(items)
  assert(action.kind == "promote" and action.item.id == blocker.id,
    "promoting a blocked item would spend a plan slot on work no "
    .. "refinement can advance: " .. action.kind)
  assert(action.reason:find("1 blocked and skipped", 1, true) ~= nil,
    "and the skip is stated: " .. action.reason)
end
test_promotion_skips_a_blocked_backlog_item()

local function test_a_full_plan_stops_promotion()
  local goal = make({})
  local items = saturated(goal)
  for _ = 1, flow.LIMITS["plan"] do
    items[#items + 1] = make({parent = goal.id, phase = "plan"})
  end
  items[#items + 1] = make({parent = goal.id, phase = "backlog"})
  local action = act.next_action(items, "me")
  assert(action.kind ~= "promote",
    "the committed queue is full and binds: " .. action.kind)
end
test_a_full_plan_stops_promotion()

-- Sweeping sits below both feeding rungs: reaching it means nothing
-- to land, review, finish or pull, triage under its bound, and `plan`
-- and `ready` both full. A keep-or-kill pass is then the most
-- valuable thing left.
local function test_sweep_offers_the_lowest_placed_rotten_item()
  local goal = make({})
  local items = saturated(goal)
  for _ = 1, flow.LIMITS["plan"] do
    items[#items + 1] = make({parent = goal.id, phase = "plan"})
  end
  local bottom = make({parent = goal.id, phase = "backlog"})
  local top = make({parent = goal.id, phase = "backlog", beats = bottom.id})
  items[#items + 1] = bottom
  items[#items + 1] = top
  local ages: {string: integer} = {
    [bottom.id] = health.ROT_S + 60,
    [top.id] = health.ROT_S + 60,
  }
  local action = act.next_action(items, "me", ages)
  assert(action.kind == "sweep" and action.item.id == bottom.id,
    "the pass converges on closing, so it asks from the bottom: "
    .. action.kind)
  assert(action.reason:find("not-planned", 1, true) ~= nil,
    "and it names the decision it wants: " .. action.reason)
end
test_sweep_offers_the_lowest_placed_rotten_item()

local function test_a_fresh_backlog_item_is_never_swept()
  local goal = make({})
  local items = saturated(goal)
  for _ = 1, flow.LIMITS["plan"] do
    items[#items + 1] = make({parent = goal.id, phase = "plan"})
  end
  local fresh = make({parent = goal.id, phase = "backlog"})
  items[#items + 1] = fresh
  local action = act.next_action(items, "me", {[fresh.id] = 60})
  assert(action.kind ~= "sweep",
    "depth is no reason to close anything; age is: " .. action.kind)
end
test_a_fresh_backlog_item_is_never_swept()

-- Decomposition used to wait on room in `plan`, so a stalled
-- refinement queue closed intake and starved the highest-placed roots
-- however far they outranked what was holding the depth. It writes
-- into the unbounded `backlog` now, so nothing throttles it.
local function test_decomposition_is_not_gated_on_the_committed_queue()
  local undriven = make({})
  local goal = make({beats = undriven.id})
  local items = saturated(goal)
  for _ = 1, flow.LIMITS["plan"] do
    items[#items + 1] = make({parent = goal.id, phase = "plan"})
  end
  items[#items + 1] = undriven
  local action = act.next_action(items, "me")
  assert(action.kind == "intake" and action.item.id == undriven.id,
    "a root nothing drives is decomposed however deep the board is: "
    .. action.kind)
end
test_decomposition_is_not_gated_on_the_committed_queue()
