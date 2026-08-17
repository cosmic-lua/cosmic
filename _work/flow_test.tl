#!/usr/bin/env cosmic
-- The flow rules are pure functions over item lists. What they pin is
-- the emergent-role claim itself: with no kind field anywhere, a
-- ranked root behaves as a goal, an unranked root as a finding, an
-- item with open children as a container, and a parented leaf as the
-- only thing the kanban moves — plus the pull order, the two-line
-- admits rule, and the goal trace as a checked graph property.

local check = require("cosmic.check")
local flow = require("_work.flow")
local item = require("_work.item")
local ksuid = require("_work.ksuid")

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

local function test_roles_emerge_from_the_graph()
  local goal = make({rank = 1})
  local finding = make({})
  local epic = make({parent = goal.id})
  local leaf = make({parent = epic.id, phase = "ready"})
  local items: {item.Item} = {goal, finding, epic, leaf}
  assert(flow.role(goal, items) == "goal", "ranked root")
  assert(flow.role(finding, items) == "finding", "unranked root")
  assert(flow.role(epic, items) == "container", "open children")
  assert(flow.role(leaf, items) == "work", "parented leaf")
end
test_roles_emerge_from_the_graph()

local function test_board_holds_open_phased_items_only()
  local goal = make({rank = 1})
  local worked = make({parent = goal.id, phase = "ready"})
  local unphased = make({parent = goal.id})
  local done = make({parent = goal.id, resolution = "completed"})
  local items: {item.Item} = {goal, worked, unphased, done}
  local b = flow.board(items)
  local total = 0
  for _, list in pairs(b) do
    total = total + #list
  end
  assert(total == 1 and b["ready"][1].id == worked.id,
    "roots, containers-in-waiting, and done items are off the board")
end
test_board_holds_open_phased_items_only()

local function test_admissions_at_the_limit()
  assert(flow.admits_over_limit("check", "land"), "an accept always lands")
  assert(flow.admits_over_limit("check", "do"), "a send-back is a return")
  assert(not flow.admits_over_limit("ready", "do"), "a pull queues")
  assert(not flow.admits_over_limit(nil, "plan"), "an entry queues")
end
test_admissions_at_the_limit()

local function test_implementer_finishes_before_pulling()
  local goal = make({rank = 1})
  local ready = make({parent = goal.id, phase = "ready"})
  local doing = make({parent = goal.id, phase = "do"})
  local landing = make({parent = goal.id, phase = "land"})
  local items: {item.Item} = {goal, ready, doing, landing}
  local action = check.must(flow.next_action(items, "implementer"))
  assert(action.kind == "finish" and action.item.id == landing.id,
    "land first, got " .. action.kind)
end
test_implementer_finishes_before_pulling()

local function test_blocked_items_are_skipped()
  local goal = make({rank = 1})
  local open_blocker = make({parent = goal.id, phase = "do"})
  local blocked = make({parent = goal.id, phase = "ready",
      blocked_by = open_blocker.id})
  local free = make({parent = goal.id, phase = "ready"})
  local items: {item.Item} = {goal, open_blocker, blocked, free}
  local action = check.must(flow.next_action(items, "implementer"))
  assert(action.kind == "finish" and action.item.id == open_blocker.id,
    "do drains first")
  local index = flow.by_id(items)
  assert(flow.is_blocked(blocked, index), "open blocker blocks")
  assert(not flow.is_blocked(free, index), "no blocker")
  local done_blocker = make({parent = goal.id, resolution = "completed"})
  local was_blocked = make({parent = goal.id, phase = "ready",
      blocked_by = done_blocker.id})
  local later = flow.by_id({goal, done_blocker, was_blocked})
  assert(not flow.is_blocked(was_blocked, later),
    "a done blocker does not block")
end
test_blocked_items_are_skipped()

local function test_planner_triages_findings_then_intakes()
  local goal = make({rank = 1})
  local idle_goal = make({rank = 2})
  local worked = make({parent = goal.id, phase = "do"})
  local finding = make({})
  local items: {item.Item} = {goal, idle_goal, worked, finding}
  local action = check.must(flow.next_action(items, "planner"))
  assert(action.kind == "triage" and action.item.id == finding.id,
    "findings before intake: " .. action.kind)
  local no_findings: {item.Item} = {goal, idle_goal, worked}
  local intake = check.must(flow.next_action(no_findings, "planner"))
  assert(intake.kind == "intake" and intake.item.id == idle_goal.id,
    "the top-ranked goal with no live work: " .. intake.kind)
end
test_planner_triages_findings_then_intakes()

local function test_trace_problems()
  local goal = make({rank = 1})
  local finding = make({})
  local orphan = make({parent = fresh_id(), phase = "plan"})
  local epic = make({parent = goal.id})
  local phased_parent = make({parent = goal.id, phase = "do"})
  local kid = make({parent = phased_parent.id, phase = "plan"})
  local untraced = make({parent = finding.id, phase = "plan"})
  local items: {item.Item} = {goal, finding, orphan, epic, phased_parent,
    kid, untraced}
  local problems = flow.trace_problems(items)
  local text = table.concat(problems, "\n")
  assert(text:find("does not exist", 1, true), "orphan parent: " .. text)
  assert(text:find("has open children", 1, true), "phased container: " .. text)
  assert(text:find("unranked", 1, true), "trace to a finding: " .. text)
end
test_trace_problems()
