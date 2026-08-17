#!/usr/bin/env cosmic
-- The flow rules are pure functions over item lists, pinned here the
-- way model_test.tl pins the label board's: the board holds open
-- slices only, two admissions survive at the limit (returns and land),
-- the pull order runs right to left with land gating pull, and the
-- goal trace is checked structurally instead of read from prose.

local check = require("cosmic.check")
local flow = require("_work.flow")
local item = require("_work.item")

local counter = 0

--- One valid item; opened stamps increase in creation order so
--- "oldest first" is the order this file created things.
local function make(kind: string, id: string, over: {string: any}): item.Item
  counter = counter + 1
  local t: {string: any} = {
    id = id, kind = kind, title = id,
    opened = ("2026-08-17T00:00:%02dZ"):format(counter),
  }
  if kind == "goal" then
    t.rank = 1
  end
  if kind == "epic" then
    t.parent = "g-one"
  end
  if kind == "slice" then
    t.parent = "e-one"
    t.phase = "ready"
  end
  for k, v in pairs(over or {}) do
    t[k] = v
  end
  -- A nil override vanishes under pairs, so "done" clears phase here:
  -- a resolved slice may not carry one and decode enforces it.
  if t.resolution ~= nil and tostring(t.resolution) ~= "" then
    t.phase = nil
  end
  return check.must(item.decode(t))
end

local function test_board_holds_open_slices_only()
  local items: {item.Item} = {
    make("goal", "g-one", {}),
    make("epic", "e-one", {}),
    make("slice", "s-one", {}),
    make("slice", "s-done", {resolution = "completed"}),
    make("finding", "f-one", {}),
  }
  local b = flow.board(items)
  assert(#(b["ready"] or {}) == 1, "one open slice in ready")
  local total = 0
  for _, list in pairs(b) do
    total = total + #list
  end
  assert(total == 1, "goals, epics, findings, and done slices are off the board")
end
test_board_holds_open_slices_only()

local function test_admissions_at_the_limit()
  assert(flow.admits_over_limit("check", "land"), "an accept always lands")
  assert(flow.admits_over_limit("check", "do"), "a send-back is a return")
  assert(not flow.admits_over_limit("ready", "do"), "a pull queues")
  assert(not flow.admits_over_limit(nil, "plan"), "an entry queues")
end
test_admissions_at_the_limit()

local function test_implementer_pull_order()
  local items: {item.Item} = {
    make("goal", "g-one", {}),
    make("epic", "e-one", {}),
    make("slice", "s-ready", {}),
    make("slice", "s-doing", {phase = "do"}),
    make("slice", "s-landing", {phase = "land"}),
  }
  local action = check.must(flow.next_action(items, "implementer"))
  assert(action.kind == "finish" and action.item.id == "s-landing",
    "land first, got " .. action.kind .. " " .. tostring(action.item))
end
test_implementer_pull_order()

local function test_full_landing_queue_drains_before_pull()
  local items: {item.Item} = {
    make("goal", "g-one", {}),
    make("epic", "e-one", {}),
    make("slice", "s-ready", {}),
  }
  local first = ""
  for i = 1, flow.LIMITS["land"] do
    local id = ("s-land-%d"):format(i)
    if first == "" then
      first = id
    end
    items[#items + 1] = make("slice", id, {phase = "land"})
  end
  local action = check.must(flow.next_action(items, "implementer"))
  assert(action.kind == "finish" and action.item.id == first,
    "a full landing queue drains before any fresh pull: " .. action.kind)
end
test_full_landing_queue_drains_before_pull()

local function test_blocked_slice_is_skipped()
  local items: {item.Item} = {
    make("goal", "g-one", {}),
    make("epic", "e-one", {}),
    make("slice", "s-blocked", {blocked_by = "s-doing"}),
    make("slice", "s-free", {}),
    make("slice", "s-doing", {resolution = "completed"}),
  }
  local open_blocker: {item.Item} = {
    make("goal", "g-one", {}),
    make("epic", "e-one", {}),
    make("slice", "s-open", {phase = "do"}),
    make("slice", "s-blocked", {blocked_by = "s-open"}),
    make("slice", "s-free", {}),
  }
  local index = flow.by_id(open_blocker)
  assert(flow.is_blocked(index["s-blocked"], index), "open blocker blocks")
  assert(not flow.is_blocked(index["s-free"], index), "no blocker")
  local closed_index = flow.by_id(items)
  assert(not flow.is_blocked(closed_index["s-blocked"], closed_index),
    "a done blocker does not block")
end
test_blocked_slice_is_skipped()

local function test_planner_intake_names_the_undriven_goal()
  local items: {item.Item} = {
    make("goal", "g-one", {}),
    make("goal", "g-two", {rank = 2}),
    make("epic", "e-one", {}),
    make("slice", "s-one", {phase = "do"}),
  }
  local action = check.must(flow.next_action(items, "planner"))
  assert(action.kind == "intake" and action.item.id == "g-two",
    "the top-ranked goal with no live work: " .. tostring(action.item))
end
test_planner_intake_names_the_undriven_goal()

local function test_trace_problems()
  local items: {item.Item} = {
    make("goal", "g-one", {}),
    make("epic", "e-one", {}),
    make("slice", "s-orphan", {parent = "nowhere"}),
    make("epic", "e-bad", {parent = "e-one"}),
  }
  local problems = flow.trace_problems(items)
  assert(#problems == 2, "want 2 problems, got " .. #problems)
  assert(problems[1]:find("does not exist", 1, true), problems[1])
  assert(problems[2]:find("must be a goal", 1, true), problems[2])
end
test_trace_problems()
