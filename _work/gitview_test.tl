#!/usr/bin/env cosmic
-- The read verbs render the board without mutating it: what `status`
-- reports as health, what `tree` calls an item whose phase is empty,
-- what `next` names for each role, and what `show` prints for one
-- item. Their output is what a session reads to decide, so the words
-- are the contract — asserted here on the pure reports the `cmd_*`
-- wrappers print.

local check = require("cosmic.check")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local store = require("_work.store")
local view = require("_work.gitview")

local counter = 0

--- A deterministic id; later calls sort later.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

local GOAL < const > = fresh_id()
local CONTAINER < const > = fresh_id()
local LEAF < const > = fresh_id()
local LIMBO < const > = fresh_id()

--- Whether any line matches a Lua pattern.
local function has(lines: {string}, pattern: string): boolean
  for _, line in ipairs(lines) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

--- The standing fixture: a ranked goal, a container under it with one
--- open child in `do`, and a leaf left with no phase.
local function board_items(): {item.Item}
  return {
    check.must(item.decode({id = GOAL, title = "a goal", rank = 1})),
    check.must(item.decode({id = CONTAINER, title = "a container",
          parent = GOAL})),
    check.must(item.decode({id = LEAF, title = "a leaf", parent = CONTAINER,
          phase = "do", claim = "session-a", pr = 42})),
    check.must(item.decode({id = LIMBO, title = "off the board",
          parent = GOAL})),
  }
end

local function test_status_counts_phases_and_names_graph_problems()
  local lines, verdict = view.status_report(board_items())
  assert(has(lines, "^do     1/5$"), table.concat(lines, "\n"))
  assert(has(lines, "@session%-a"), "the claim shows")
  assert(has(lines, "pr:42"), "so does the PR")
  assert(has(lines, "graph: " .. LIMBO .. ":"),
    "an item off the board is board health: " .. table.concat(lines, "\n"))
  assert(verdict == "WIP ok; 1 graph problem(s)", verdict)
end
test_status_counts_phases_and_names_graph_problems()

local function test_status_reports_a_phase_over_its_limit()
  local items = board_items()
  for _ = 1, 5 do
    items[#items + 1] = check.must(item.decode({id = fresh_id(),
          title = "more", parent = CONTAINER, phase = "do"}))
  end
  local _, verdict = view.status_report(items)
  assert(verdict:find("do 6/5 over limit", 1, true), verdict)
end
test_status_reports_a_phase_over_its_limit()

local function test_tree_separates_containers_from_unphased_leaves()
  local lines, verdict = view.tree_report(board_items())
  assert(has(lines, "^G1 " .. GOAL:sub(1, 8) .. " a goal$"),
    table.concat(lines, "\n"))
  assert(has(lines, CONTAINER:sub(1, 8) .. " %[container%]"),
    "an item with an open child is a container")
  assert(has(lines, LIMBO:sub(1, 8) .. " %[unphased%]"),
    "a leaf with no phase is NOT one: " .. table.concat(lines, "\n"))
  assert(has(lines, LEAF:sub(1, 8) .. " %[do%]"), "the leaf shows its phase")
  assert(verdict == "1 open goal(s), 0 finding(s) awaiting triage", verdict)
end
test_tree_separates_containers_from_unphased_leaves()

local function test_tree_marks_a_goal_nothing_is_driving()
  local only_goal: {item.Item} = {
    check.must(item.decode({id = GOAL, title = "a goal", rank = 1})),
    check.must(item.decode({id = LIMBO, title = "a finding"})),
  }
  local lines, verdict = view.tree_report(only_goal)
  assert(has(lines, "%(no live work%)"), table.concat(lines, "\n"))
  assert(has(lines, "^finding " .. LIMBO:sub(1, 8)), "findings queue below")
  assert(verdict:find("1 finding(s)", 1, true), verdict)
end
test_tree_marks_a_goal_nothing_is_driving()

local function test_next_answers_per_role()
  local mine = check.must(view.next_report(board_items(), "implementer"))
  assert(mine:find("finish", 1, true) and mine:find(LEAF:sub(1, 8), 1, true),
    "work in do is finished before anything is pulled: " .. mine)
  local theirs = check.must(view.next_report(board_items(), "planner"))
  assert(theirs:find("intake", 1, true) or theirs:find("refine", 1, true),
    "the planner refines or takes in: " .. theirs)
  local bad, err = view.next_report(board_items(), "nobody")
  assert(bad == nil and err:find("unknown role", 1, true), tostring(err))
end
test_next_answers_per_role()

local function test_show_prints_fields_role_and_history()
  local all = board_items()
  local events: {store.Event} = {
    {sha = "abc1234", at = "2026-08-17T00:00:00Z", subject = "move it"},
  }
  local lines, verdict = view.show_report(all[3], all, "## Goal\nserves G1\n",
    events)
  assert(has(lines, "^role: work$"), table.concat(lines, "\n"))
  assert(has(lines, "^phase: do$"), "its phase")
  assert(has(lines, "^pr: #42$"), "its PR")
  assert(has(lines, "^%-%-%- spec %-%-%-$"), "the sidecar is the spec")
  assert(has(lines, "abc1234 move it"), "git log IS the item's history")
  assert(verdict == LEAF:sub(1, 8) .. " is do", verdict)
end
test_show_prints_fields_role_and_history()

local function test_show_names_an_items_own_graph_problem()
  local all = board_items()
  local lines, verdict = view.show_report(all[4], all, "", {})
  assert(has(lines, "graph: .* no phase"),
    "an item off the board says so where it is read: "
    .. table.concat(lines, "\n"))
  assert(verdict:find("is open", 1, true), verdict)
end
test_show_names_an_items_own_graph_problem()
