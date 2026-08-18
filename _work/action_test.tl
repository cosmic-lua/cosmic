#!/usr/bin/env cosmic
-- What the one next action is, per role. The order is the system's
-- central claim — finishing beats starting, both ways down the board
-- — and the claim filter is what makes that order safe to ask when
-- several implementer sessions run at once.

local check = require("cosmic.check")
local flow = require("_work.flow")
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

local function test_implementer_finishes_before_pulling()
  local goal = make({})
  local ready = make({parent = goal.id, phase = "ready"})
  local doing = make({parent = goal.id, phase = "do"})
  local landing = make({parent = goal.id, phase = "land"})
  local items: {item.Item} = {goal, ready, doing, landing}
  local action = check.must(act.for_role(items, "implementer"))
  assert(action.kind == "finish" and action.item.id == landing.id,
    "land first, got " .. action.kind)
end
test_implementer_finishes_before_pulling()

local function test_blocked_ready_items_are_not_pulled()
  local goal = make({})
  local blocker = make({parent = goal.id, phase = "plan"})
  local blocked = make({parent = goal.id, phase = "ready",
      blocked_by = blocker.id})
  local free = make({parent = goal.id, phase = "ready"})
  local items: {item.Item} = {goal, blocker, blocked, free}
  local action = check.must(act.for_role(items, "implementer"))
  assert(action.kind == "pull" and action.item.id == free.id,
    "the blocked item is skipped for the free one: " .. action.kind)
end
test_blocked_ready_items_are_not_pulled()

local function test_another_sessions_claim_is_not_handed_over()
  local goal = make({})
  local theirs = make({parent = goal.id, phase = "do", claim = "session-A"})
  local ready = make({parent = goal.id, phase = "ready"})
  local items: {item.Item} = {goal, theirs, ready}
  local mine = check.must(act.for_role(items, "implementer", "session-B"))
  assert(mine.kind == "pull" and mine.item.id == ready.id,
    "B pulls rather than finishing A's claim: " .. mine.kind)
  local theirs_again = check.must(
    act.for_role(items, "implementer", "session-A"))
  assert(theirs_again.kind == "finish" and theirs_again.item.id == theirs.id,
    "A finishes its own claim: " .. theirs_again.kind)
end
test_another_sessions_claim_is_not_handed_over()

local function test_an_unclaimed_do_item_is_anyones()
  local goal = make({})
  local loose = make({parent = goal.id, phase = "do"})
  local items: {item.Item} = {goal, loose}
  local action = check.must(act.for_role(items, "implementer", "session-B"))
  assert(action.kind == "finish" and action.item.id == loose.id,
    "an unclaimed do item is finishable by anyone: " .. action.kind)
end
test_an_unclaimed_do_item_is_anyones()

local function test_an_unnamed_session_skips_nothing_but_says_whose()
  local goal = make({})
  local theirs = make({parent = goal.id, phase = "do", claim = "session-A"})
  local items: {item.Item} = {goal, theirs}
  local action = check.must(act.for_role(items, "implementer"))
  assert(action.kind == "finish" and action.item.id == theirs.id,
    "a session that names nothing is held back by nothing")
  assert(action.reason:find("claimed by session-A", 1, true),
    "and is told whose it is: " .. action.reason)
end
test_an_unnamed_session_skips_nothing_but_says_whose()

local function test_held_work_with_nothing_to_pull_says_so()
  local goal = make({})
  local theirs = make({parent = goal.id, phase = "do", claim = "session-A"})
  local items: {item.Item} = {goal, theirs}
  local action = check.must(act.for_role(items, "implementer", "session-B"))
  assert(action.kind == "none", "nothing for B to do: " .. action.kind)
  assert(action.reason:find("claimed by other sessions", 1, true),
    "and the reason names why: " .. action.reason)
end
test_held_work_with_nothing_to_pull_says_so()

-- Placement is what separates the two: an unplaced capture is
-- triage, a placed root nothing drives is intake.
local function test_planner_triages_captures_then_intakes()
  local idle = make({})
  local driven = make({beats = idle.id})
  local worked = make({parent = driven.id, phase = "do"})
  local captured = make({})
  local items: {item.Item} = {idle, driven, worked, captured}
  local action = check.must(act.for_role(items, "planner"))
  assert(action.kind == "triage" and action.item.id == captured.id,
    "an unplaced capture outranks intake: " .. action.kind)
  local drained: {item.Item} = {idle, driven, worked}
  local intake = check.must(act.for_role(drained, "planner"))
  assert(intake.kind == "intake" and intake.item.id == idle.id,
    "the placed root with no live work: " .. intake.kind)
end
test_planner_triages_captures_then_intakes()

local function test_planner_reviews_before_everything()
  local goal = make({})
  local planning = make({parent = goal.id, phase = "plan"})
  local checking = make({parent = goal.id, phase = "check", pr = 7})
  local items: {item.Item} = {goal, planning, checking}
  local action = check.must(act.for_role(items, "planner"))
  assert(action.kind == "review" and action.item.id == checking.id,
    "verdicts come before refinement: " .. action.kind)
end
test_planner_reviews_before_everything()

local function test_an_unknown_role_is_an_error()
  local action, err = act.for_role({}, "reviewer")
  assert(action == nil, "no action for an unknown role")
  assert(err:find("unknown role", 1, true), "got: " .. tostring(err))
end
test_an_unknown_role_is_an_error()

local function test_an_over_bound_triage_queue_outranks_refining()
  local goal = make({})
  local planning = make({parent = goal.id, phase = "plan"})
  local items: {item.Item} = {goal, planning}
  local oldest: item.Item = nil
  for _ = 1, flow.TRIAGE_LIMIT do
    local finding = make({})
    oldest = oldest or finding
    items[#items + 1] = finding
  end
  local under = check.must(act.for_role(items, "planner"))
  assert(under.kind == "refine" and under.item.id == planning.id,
    "at the bound, ready has slack and refinement still wins: " .. under.kind)
  items[#items + 1] = make({})
  local over = check.must(act.for_role(items, "planner"))
  assert(over.kind == "triage" and over.item.id == oldest.id,
    "past the bound, the oldest finding is drained first: " .. over.kind)
  assert(over.reason:find("outranks refining", 1, true), over.reason)
end
test_an_over_bound_triage_queue_outranks_refining()

local function test_verdicts_outrank_an_over_bound_triage_queue()
  local goal = make({})
  local checking = make({parent = goal.id, phase = "check", pr = 7})
  local items: {item.Item} = {goal, checking}
  for _ = 1, flow.TRIAGE_LIMIT + 1 do
    items[#items + 1] = make({})
  end
  local action = check.must(act.for_role(items, "planner"))
  assert(action.kind == "review" and action.item.id == checking.id,
    "check is still the rightmost planner phase: " .. action.kind)
end
test_verdicts_outrank_an_over_bound_triage_queue()
