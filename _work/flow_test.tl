#!/usr/bin/env cosmic
-- The flow rules are pure functions over item lists. What they pin is
-- the emergent-role claim itself: with no kind field anywhere, a
-- parentless item reads as a root, one with open children as a
-- container, and a parented leaf as the only thing the kanban moves —
-- plus the return a limit never holds back, the blocker relation, and
-- placement in the priority order as a graph property. What a role
-- does with all this is `_work/action_test.tl`.

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
  local top = make({})
  local captured = make({})
  local epic = make({parent = top.id})
  local leaf = make({parent = epic.id, phase = "ready"})
  local items: {item.Item} = {top, captured, epic, leaf}
  assert(flow.role(top, items) == "container", "a root with children")
  assert(flow.role(captured, items) == "root", "a childless root")
  assert(flow.role(epic, items) == "container", "open children")
  assert(flow.role(leaf, items) == "work", "parented leaf")
end
test_roles_emerge_from_the_graph()

local function test_board_holds_open_phased_items_only()
  local goal = make({})
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

local function test_a_return_is_admitted_over_a_limit()
  assert(flow.is_return("check", "do"), "a send-back is a return")
  assert(not flow.is_return("ready", "do"), "a pull queues")
  assert(not flow.is_return(nil, "plan"), "an entry queues")
end
test_a_return_is_admitted_over_a_limit()

local function test_arrivals_versus_writes_that_move_nothing()
  assert(flow.is_arrival(nil, "plan"), "an entry arrives")
  assert(flow.is_arrival("do", "check"), "a cross-phase move arrives")
  assert(not flow.is_arrival("plan", "plan"),
    "a same-phase write (spec, block) does not arrive")
  assert(not flow.is_arrival("plan", ""), "de-phasing arrives nowhere")
end
test_arrivals_versus_writes_that_move_nothing()

local function test_blocked_items_are_skipped()
  local goal = make({})
  local open_blocker = make({parent = goal.id, phase = "do"})
  local blocked = make({parent = goal.id, phase = "ready",
      blocked_by = open_blocker.id})
  local free = make({parent = goal.id, phase = "ready"})
  local items: {item.Item} = {goal, open_blocker, blocked, free}
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

local function test_graph_problems()
  local goal = make({})
  local finding = make({})
  local orphan = make({parent = fresh_id(), phase = "plan"})
  local epic = make({parent = goal.id})
  local phased_parent = make({parent = goal.id, phase = "do"})
  local kid = make({parent = phased_parent.id, phase = "plan"})
  local untraced = make({parent = finding.id, phase = "plan"})
  local items: {item.Item} = {goal, finding, orphan, epic, phased_parent,
    kid, untraced}
  local problems = flow.graph_problems(items)
  local text = table.concat(problems, "\n")
  assert(text:find("does not exist", 1, true), "orphan parent: " .. text)
  assert(text:find("has open children", 1, true), "phased container: " .. text)
  assert(text:find("no position in the priority order", 1, true),
    "phased work nothing has placed: " .. text)
end
test_graph_problems()

local function test_waits_on_follows_a_blocker_chain()
  local goal = make({})
  local a = make({parent = goal.id, phase = "ready"})
  local b = make({parent = goal.id, phase = "ready", blocked_by = a.id})
  local c = make({parent = goal.id, phase = "ready", blocked_by = b.id})
  local index = flow.by_id({goal, a, b, c})
  assert(flow.waits_on(index, c.id, a.id), "c waits on a through b")
  assert(not flow.waits_on(index, a.id, c.id), "and a waits on nothing")
end
test_waits_on_follows_a_blocker_chain()

local function test_waits_on_terminates_on_a_cycle_already_in_the_data()
  local goal = make({})
  local a = make({parent = goal.id, phase = "ready"})
  local b = make({parent = goal.id, phase = "ready", blocked_by = a.id})
  a.blocked_by = {b.id}
  local index = flow.by_id({goal, a, b})
  assert(flow.waits_on(index, a.id, b.id), "the cycle is still reported")
  local elsewhere = make({parent = goal.id, phase = "ready"})
  assert(not flow.waits_on(index, a.id, elsewhere.id),
    "and a walk that finds nothing still returns rather than spinning")
end
test_waits_on_terminates_on_a_cycle_already_in_the_data()

local function test_the_triage_queue_has_a_bound()
  local queue: {item.Item} = {}
  for _ = 1, flow.TRIAGE_LIMIT do
    queue[#queue + 1] = make({})
  end
  assert(flow.triage_violation(queue) == nil,
    "a queue at the bound is not a violation")
  queue[#queue + 1] = make({})
  local over = flow.triage_violation(queue)
  local want = ("triage %d/%d over limit"):format(flow.TRIAGE_LIMIT + 1,
    flow.TRIAGE_LIMIT)
  assert(over == want, "got: " .. tostring(over))
end
test_the_triage_queue_has_a_bound()

-- The gate refuses an ordinary arrival from `count == limit` upward,
-- so a phase sitting exactly at its number is already turning work
-- away. Reporting only `count > limit` printed `WIP ok` over a board
-- that could not accept another item.
local function test_a_phase_at_its_limit_reports_arrivals_refused()
  local root = make({})
  local under: {item.Item} = {root}
  for _ = 1, flow.LIMITS["do"] - 1 do
    under[#under + 1] = make({parent = root.id, phase = "do"})
  end
  assert(#flow.wip_violations(flow.board(under)) == 0,
    "below the limit reports nothing")
  local at: {item.Item} = {root}
  for _ = 1, flow.LIMITS["do"] do
    at[#at + 1] = make({parent = root.id, phase = "do"})
  end
  local lines = flow.wip_violations(flow.board(at))
  assert(#lines == 1 and lines[1]:find("at limit — arrivals refused", 1, true),
    "at the limit it says arrivals are refused: " .. table.concat(lines, "; "))
  local over: {item.Item} = {root}
  for _ = 1, flow.LIMITS["do"] + 1 do
    over[#over + 1] = make({parent = root.id, phase = "do"})
  end
  local past = flow.wip_violations(flow.board(over))
  assert(#past == 1 and past[1]:find("over limit", 1, true),
    "past it, the older line stands: " .. table.concat(past, "; "))
end
test_a_phase_at_its_limit_reports_arrivals_refused()

-- `land` holds no limit at all: it is the rightmost phase, where the
-- only move left is out of the system, so however many items stand
-- there none of them is an arrival being turned away.
local function test_land_is_unbounded()
  assert(flow.LIMITS["land"] == nil, "land holds no WIP limit")
  local root = make({})
  local items: {item.Item} = {root}
  for _ = 1, 12 do
    items[#items + 1] = make({parent = root.id, phase = "land"})
  end
  assert(#flow.wip_violations(flow.board(items)) == 0,
    "a deep land column is not turning anything away")
end
test_land_is_unbounded()
