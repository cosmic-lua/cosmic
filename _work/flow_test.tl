#!/usr/bin/env cosmic
-- The flow rules are pure functions over item lists. What they pin is
-- the emergent-role and derived-state claims themselves: with no kind
-- field and no phase field anywhere, a parentless item reads as a
-- root, one with open children as a container, and a parented leaf as
-- workable — todo while unclaimed and PR-less, doing otherwise, with
-- the substate read off the same facts. Plus the one doing bound, the
-- blocker relation, and the graph problems `status` reports. What a
-- session DOES with all this is `_work/action_test.tl`.

local check = require("cosmic.check")
local flow = require("_work.flow")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local prio = require("_work.priority")

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
  local leaf = make({parent = epic.id})
  local items: {item.Item} = {top, captured, epic, leaf}
  assert(flow.role(top, items) == "container", "a root with children")
  assert(flow.role(captured, items) == "root", "a childless root")
  assert(flow.role(epic, items) == "container", "open children")
  assert(flow.role(leaf, items) == "work", "parented leaf")
end
test_roles_emerge_from_the_graph()

local function test_state_derives_from_the_facts()
  local goal = make({})
  local fresh = make({parent = goal.id})
  local claimed = make({parent = goal.id, claim = "session-A"})
  local handed = make({parent = goal.id, claim = "session-A", pr = 7})
  local sent_back = make({parent = goal.id, claim = "session-A", pr = 7,
      verdict = "request changes"})
  local judged = make({parent = goal.id, claim = "session-A", pr = 7,
      verdict = "accept"})
  assert(not flow.is_doing(fresh), "unclaimed and PR-less is todo")
  assert(flow.is_doing(claimed) and flow.substate(claimed) == "building",
    "a claim alone is a build in progress")
  assert(flow.substate(handed) == "review", "a PR with no verdict awaits one")
  assert(flow.substate(sent_back) == "rework", "a send-back is rework")
  assert(flow.substate(judged) == "accepted", "an accept awaits its merge")
end
test_state_derives_from_the_facts()

local function test_in_state_holds_open_workable_leaves_only()
  local goal = make({})
  local todo = make({parent = goal.id})
  local doing = make({parent = goal.id, claim = "session-A"})
  local done = make({parent = goal.id, resolution = "completed"})
  local capture = make({})
  local items: {item.Item} = {goal, todo, doing, done, capture}
  local pos = prio.positions(items)
  local todos = flow.in_state(items, "todo", pos)
  assert(#todos == 1 and todos[1].id == todo.id,
    "roots, containers, doing and done items are not todo")
  local doings = flow.in_state(items, "doing", pos)
  assert(#doings == 1 and doings[1].id == doing.id,
    "only the claimed leaf is doing")
end
test_in_state_holds_open_workable_leaves_only()

local function test_the_doing_bound_binds_new_takes_only()
  local root = make({})
  local items: {item.Item} = {root}
  for k = 1, flow.DOING_LIMIT - 1 do
    items[#items + 1] = make({parent = root.id,
        claim = ("wake-%d"):format(k)})
  end
  assert(flow.doing_refusal(items) == nil,
    "below the bound nothing is refused")
  items[#items + 1] = make({parent = root.id, pr = 9})
  local over = flow.doing_refusal(items)
  assert(over ~= nil and over:find("finish something", 1, true),
    "at the bound a new take is refused: " .. tostring(over))
end
test_the_doing_bound_binds_new_takes_only()

local function test_blocked_items_are_skipped()
  local goal = make({})
  local open_blocker = make({parent = goal.id, claim = "session-A"})
  local blocked = make({parent = goal.id, blocked_by = open_blocker.id})
  local free = make({parent = goal.id})
  local items: {item.Item} = {goal, open_blocker, blocked, free}
  local index = flow.by_id(items)
  assert(flow.is_blocked(blocked, index), "open blocker blocks")
  assert(not flow.is_blocked(free, index), "no blocker")
  local done_blocker = make({parent = goal.id, resolution = "completed"})
  local was_blocked = make({parent = goal.id,
      blocked_by = done_blocker.id})
  local later = flow.by_id({goal, done_blocker, was_blocked})
  assert(not flow.is_blocked(was_blocked, later),
    "a done blocker does not block")
end
test_blocked_items_are_skipped()

local function test_graph_problems()
  local goal = make({})
  local finding = make({})
  local orphan = make({parent = fresh_id()})
  local epic = make({parent = goal.id})
  local kid = make({parent = epic.id})
  local items: {item.Item} = {goal, finding, orphan, epic, kid}
  local problems = flow.graph_problems(items)
  local text = table.concat(problems, "\n")
  assert(text:find("does not exist", 1, true), "orphan parent: " .. text)
  assert(#problems == 1, "nothing else is a graph problem: " .. text)
end
test_graph_problems()

local function test_waits_on_follows_a_blocker_chain()
  local goal = make({})
  local a = make({parent = goal.id})
  local b = make({parent = goal.id, blocked_by = a.id})
  local c = make({parent = goal.id, blocked_by = b.id})
  local index = flow.by_id({goal, a, b, c})
  assert(flow.waits_on(index, c.id, a.id), "c waits on a through b")
  assert(not flow.waits_on(index, a.id, c.id), "and a waits on nothing")
end
test_waits_on_follows_a_blocker_chain()

local function test_waits_on_terminates_on_a_cycle_already_in_the_data()
  local goal = make({})
  local a = make({parent = goal.id})
  local b = make({parent = goal.id, blocked_by = a.id})
  a.blocked_by = {b.id}
  local index = flow.by_id({goal, a, b})
  assert(flow.waits_on(index, a.id, b.id), "the cycle is still reported")
  local elsewhere = make({parent = goal.id})
  assert(not flow.waits_on(index, a.id, elsewhere.id),
    "and a walk that finds nothing still returns rather than spinning")
end
test_waits_on_terminates_on_a_cycle_already_in_the_data()

local function test_untriaged_holds_unplaced_childless_roots()
  local placed = make({})
  local lesser = make({})
  placed.beats = {lesser.id}
  local capture = make({})
  local adopted = make({parent = placed.id})
  local items: {item.Item} = {placed, lesser, capture, adopted}
  local queue = flow.untriaged(items)
  assert(#queue == 1 and queue[1].id == capture.id,
    "compared roots and adopted leaves are not triage")
end
test_untriaged_holds_unplaced_childless_roots()

-- The unified order: ONE queue, stage first — accepted, review,
-- rework, building, lane repair, todo — then the priority order
-- within a stage. Stage is lexicographically supreme: no comparison
-- edge lifts a todo item past a waiting verdict, however hot.
local function test_unified_ranks_stage_before_priority()
  local lesser = make({})
  local goal = make({})
  goal.beats = {lesser.id}
  local accepted = make({parent = goal.id, claim = "s1", pr = 4,
      verdict = "accept"})
  local reviewable = make({parent = goal.id, claim = "s2", pr = 5})
  local reworking = make({parent = goal.id, claim = "s3", pr = 6,
      verdict = "request changes"})
  local building = make({parent = goal.id, claim = "s4"})
  local repair = make({parent = goal.id, lane = "release.yml"})
  local hot = make({parent = goal.id})
  -- The todo item outranks EVERYTHING in the comparison order…
  hot.beats = {accepted.id, reviewable.id, reworking.id, building.id,
    repair.id}
  local items: {item.Item} = {lesser, goal, hot, repair, building,
    reworking, reviewable, accepted}
  assert(flow.stage_rank(accepted) == flow.STAGE_ACCEPTED)
  assert(flow.stage_rank(reviewable) == flow.STAGE_REVIEW)
  assert(flow.stage_rank(reworking) == flow.STAGE_REWORK)
  assert(flow.stage_rank(building) == flow.STAGE_BUILDING)
  assert(flow.stage_rank(repair) == flow.STAGE_REPAIR)
  assert(flow.stage_rank(hot) == flow.STAGE_TODO)
  local queue = flow.unified(items, prio.positions(items))
  local order: {string} = {}
  for _, i in ipairs(queue) do
    order[#order + 1] = i.id
  end
  -- …and still ranks last: stage beats priority, priority only
  -- breaks ties within a stage.
  assert(#queue == 6, "every open workable item, roots excluded")
  assert(order[1] == accepted.id and order[2] == reviewable.id
    and order[3] == reworking.id and order[4] == building.id
    and order[5] == repair.id and order[6] == hot.id,
    "stage-lexicographic: " .. table.concat(order, " "))
end
test_unified_ranks_stage_before_priority()

-- Within one stage the priority order decides: a compared-up todo
-- item comes before its uncompared sibling.
local function test_unified_breaks_stage_ties_by_priority()
  local lesser = make({})
  local goal = make({})
  goal.beats = {lesser.id}
  local plain = make({parent = goal.id})
  local hot = make({parent = goal.id})
  hot.beats = {plain.id}
  local items: {item.Item} = {lesser, goal, plain, hot}
  local queue = flow.unified(items, prio.positions(items))
  assert(#queue == 2 and queue[1].id == hot.id and queue[2].id == plain.id,
    "the comparison order holds within the stage")
end
test_unified_breaks_stage_ties_by_priority()
