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
local fixture = require("_work.fixture")
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
local LESSER < const > = fresh_id()

--- Whether any line matches a Lua pattern.
local function has(lines: {string}, pattern: string): boolean
  for _, line in ipairs(lines) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

--- The standing fixture: a placed root (it outranks LESSER, which is
--- what gives everything beneath it a position), a container under it
--- with one open child in `do`, and a leaf left with no phase.
local function board_items(): {item.Item}
  return {
    check.must(item.decode({id = GOAL, title = "a goal", beats = LESSER})),
    check.must(item.decode({id = CONTAINER, title = "a container",
          parent = GOAL})),
    check.must(item.decode({id = LEAF, title = "a leaf", parent = CONTAINER,
          phase = "do", claim = "session-a", pr = 42})),
    check.must(item.decode({id = LIMBO, title = "off the board",
          parent = GOAL})),
    check.must(item.decode({id = LESSER, title = "a lesser outcome"})),
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
  assert(has(lines, "^%[>1%] " .. GOAL:sub(1, 8) .. " a goal$"),
    "a placed root leads with what it outranks: " .. table.concat(lines, "\n"))
  assert(has(lines, CONTAINER:sub(1, 8) .. " %[container%]"),
    "an item with an open child is a container")
  assert(has(lines, LIMBO:sub(1, 8) .. " %[unphased%]"),
    "a leaf with no phase is NOT one: " .. table.concat(lines, "\n"))
  assert(has(lines, LEAF:sub(1, 8) .. " %[do%]"), "the leaf shows its phase")
  assert(verdict == "2 organizing root(s), 0 item(s) awaiting triage", verdict)
end
test_tree_separates_containers_from_unphased_leaves()

local function test_tree_marks_a_root_nothing_is_driving()
  local only_root: {item.Item} = {
    check.must(item.decode({id = GOAL, title = "a goal", beats = LESSER})),
    check.must(item.decode({id = LESSER, title = "a lesser outcome"})),
    check.must(item.decode({id = LIMBO, title = "a capture"})),
  }
  local lines, verdict = view.tree_report(only_root)
  assert(has(lines, "%(no live work%)"), table.concat(lines, "\n"))
  assert(has(lines, "^triage " .. LIMBO:sub(1, 8)),
    "an unplaced capture queues below: " .. table.concat(lines, "\n"))
  assert(verdict:find("1 item(s) awaiting triage", 1, true), verdict)
end
test_tree_marks_a_root_nothing_is_driving()

local function test_next_names_one_action_and_its_rule()
  local report = view.next_report(board_items())
  assert(report:find("finish", 1, true)
    and report:find(LEAF:sub(1, 8), 1, true),
    "work in do is finished before anything is pulled: " .. report)
  assert(report:find("—", 1, true),
    "and the rule that chose it is stated: " .. report)
end
test_next_names_one_action_and_its_rule()

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

-- `blocked by` means what `flow.is_blocked` means: an edge whose
-- blocker has ended does not hold the item up, and printing it beside
-- the ones that do reads as a chain far deeper than it is. The closed
-- edges stay visible under their own heading — they are the record of
-- what the item waited on — and an item every blocker of which has
-- ended prints no `blocked by` line at all.
local function test_show_separates_binding_blockers_from_cleared_ones()
  local all = board_items()
  local open_blocker = fresh_id()
  local ended_blocker = fresh_id()
  all[#all + 1] = check.must(item.decode({id = open_blocker,
        title = "still open", parent = CONTAINER, phase = "plan"}))
  all[#all + 1] = check.must(item.decode({id = ended_blocker,
        title = "landed already", parent = CONTAINER,
        resolution = "completed"}))
  local waiting = check.must(item.decode({id = fresh_id(),
        title = "waits on one of them", parent = CONTAINER, phase = "plan",
        blocked_by = open_blocker .. " " .. ended_blocker}))
  all[#all + 1] = waiting
  local lines = view.show_report(waiting, all, "", {})
  assert(has(lines, "^blocked by: " .. open_blocker .. "$"),
    "only the open blocker binds: " .. table.concat(lines, "\n"))
  assert(has(lines, "^blockers cleared: " .. ended_blocker .. "$"),
    "the ended edge is still the record: " .. table.concat(lines, "\n"))

  local settled = check.must(item.decode({id = fresh_id(),
        title = "waits on nothing open", parent = CONTAINER, phase = "plan",
        blocked_by = ended_blocker}))
  all[#all + 1] = settled
  local settled_lines = view.show_report(settled, all, "", {})
  assert(not has(settled_lines, "^blocked by:"),
    "nothing open holds it up: " .. table.concat(settled_lines, "\n"))
  assert(has(settled_lines, "^blockers cleared: " .. ended_blocker .. "$"),
    "and the edge is still shown: " .. table.concat(settled_lines, "\n"))
end
test_show_separates_binding_blockers_from_cleared_ones()

-- Cross-repo work is visible exactly where it was invisible: `show`
-- prints a `repo:` line, and the queue/tree reports append
-- ` [owner/name]` to the item's line. The default (empty `repo`) is
-- silent — a same-repo item reads the same as it did before this field
-- existed.
local function test_repo_is_rendered_in_show_status_and_tree()
  local all = board_items()
  local scoped = check.must(item.decode({
        id = fresh_id(), title = "a cosmopolitan-side slice",
        parent = CONTAINER, phase = "do", repo = "whilp/cosmopolitan"}))
  all[#all + 1] = scoped

  local show_lines = view.show_report(scoped, all, "", {})
  assert(has(show_lines, "^repo: whilp/cosmopolitan$"),
    "show prints a repo line: " .. table.concat(show_lines, "\n"))

  local status_lines = view.status_report(all)
  assert(has(status_lines, "%[whilp/cosmopolitan%]"),
    "status marks the item with its repo: " .. table.concat(status_lines, "\n"))
  -- The mark means "cross-repo", so it must not reach a same-repo
  -- line. Hold the LEAF's line before asserting about it: `status`
  -- writes a PR as ` pr:42` where `show` writes `pr: #42`, and a
  -- negative assertion over a pattern from the wrong report matches
  -- nothing and passes however badly the mark leaks.
  local leaf_line = ""
  for _, line in ipairs(status_lines) do
    if line:find("pr:42", 1, true) then
      leaf_line = line
    end
  end
  assert(leaf_line ~= "", "the LEAF's status line is there to check")
  assert(not leaf_line:find("whilp/cosmopolitan", 1, true),
    "the same-repo LEAF is unmarked: " .. leaf_line)

  local tree_lines = view.tree_report(all)
  assert(has(tree_lines, "%[whilp/cosmopolitan%]"),
    "tree marks the item with its repo: " .. table.concat(tree_lines, "\n"))

  local default_show = view.show_report(all[3], all, "", {})
  assert(not has(default_show, "^repo:"),
    "an item with no repo prints no repo line: "
    .. table.concat(default_show, "\n"))
end
test_repo_is_rendered_in_show_status_and_tree()

local function test_status_counts_the_triage_queue_against_its_bound()
  local lines, verdict = view.status_report(board_items())
  assert(has(lines, "^triage 0/8$"), table.concat(lines, "\n"))
  assert(not verdict:find("triage", 1, true),
    "an empty queue is no violation: " .. verdict)
  local items = board_items()
  for _ = 1, 9 do
    items[#items + 1] = check.must(item.decode({id = fresh_id(),
          title = "a finding"}))
  end
  local over, over_verdict = view.status_report(items)
  assert(has(over, "^triage 9/8$"), table.concat(over, "\n"))
  assert(over_verdict:find("triage 9/8 over limit", 1, true), over_verdict)
end
test_status_counts_the_triage_queue_against_its_bound()

--- The fixture plus one ended item, so a search can be asked the
--- question it exists for: has this already been filed?
local ENDED < const > = fresh_id()

local function searchable_items(): {item.Item}
  local items = board_items()
  items[#items + 1] = check.must(item.decode({id = ENDED,
        title = "a closed duplicate", parent = CONTAINER,
        resolution = "not-planned"}))
  return items
end

local function test_find_matches_titles_and_spec_bodies()
  local specs: {string: string} = {
    [CONTAINER] = "## Goal\n   serves the widget pipeline\nand nothing else\n",
  }
  local titled, tverdict = view.find_report(searchable_items(), specs, "leaf")
  assert(#titled == 1, table.concat(titled, "\n"))
  assert(has(titled, "^" .. LEAF:sub(1, 8) .. " %[do%] a leaf$"),
    table.concat(titled, "\n"))
  assert(tverdict == "1 item(s) matching \"leaf\"", tverdict)
  local bodied, bverdict = view.find_report(searchable_items(), specs, "widget")
  assert(has(bodied, "^" .. CONTAINER:sub(1, 8) .. " %[container%] a container$"),
    "a body-only hit still names the item: " .. table.concat(bodied, "\n"))
  assert(has(bodied, "^    serves the widget pipeline$"),
    "and carries the line that matched, trimmed: "
    .. table.concat(bodied, "\n"))
  assert(bverdict == "1 item(s) matching \"widget\"", bverdict)
end
test_find_matches_titles_and_spec_bodies()

local function test_find_ignores_case_in_both_directions()
  local specs: {string: string} = {[LIMBO] = "The WIDGET again\n"}
  local upper = view.find_report(searchable_items(), specs, "A GOAL")
  assert(has(upper, GOAL:sub(1, 8) .. " %[container%] a goal"),
    "an upper-case term finds a lower-case title: "
    .. table.concat(upper, "\n"))
  local lower = view.find_report(searchable_items(), specs, "widget")
  assert(has(lower, "^    The WIDGET again$"),
    "and a lower-case one an upper-case body: " .. table.concat(lower, "\n"))
end
test_find_ignores_case_in_both_directions()

local function test_find_includes_ended_items_tagged_by_resolution()
  local lines, verdict = view.find_report(searchable_items(), {}, "duplicate")
  assert(has(lines, "^" .. ENDED:sub(1, 8)
      .. " %[done: not%-planned%] a closed duplicate$"),
    "a finding already filed AND closed is exactly what a duplicate check "
    .. "must see: " .. table.concat(lines, "\n"))
  assert(verdict == "1 item(s) matching \"duplicate\"", verdict)
end
test_find_includes_ended_items_tagged_by_resolution()

local function test_find_reports_no_match_as_a_verdict_not_an_error()
  local lines, verdict = view.find_report(searchable_items(), {}, "sasquatch")
  assert(#lines == 0, table.concat(lines, "\n"))
  assert(verdict == "0 item(s) matching \"sasquatch\"", verdict)
end
test_find_reports_no_match_as_a_verdict_not_an_error()

local function test_find_matches_the_term_literally_not_as_a_pattern()
  local dotted = fresh_id()
  local decoy = fresh_id()
  local items = searchable_items()
  items[#items + 1] = check.must(item.decode({id = dotted,
        title = "the a.b gate", parent = CONTAINER}))
  items[#items + 1] = check.must(item.decode({id = decoy,
        title = "the axb gate", parent = CONTAINER}))
  local lines, verdict = view.find_report(items, {}, "a.b")
  assert(#lines == 1 and has(lines, dotted:sub(1, 8) .. " %[work%] "),
    "a term is text, never a pattern: " .. table.concat(lines, "\n"))
  assert(verdict == "1 item(s) matching \"a.b\"", verdict)
  local pct = view.find_report(items, {[dotted] = "100% of the time\n"}, "100%")
  assert(has(pct, "^    100%% of the time$"),
    "and a term with a Lua escape is no different: "
    .. table.concat(pct, "\n"))
end
test_find_matches_the_term_literally_not_as_a_pattern()

local function test_find_reads_the_sidecars_and_refuses_an_empty_term()
  local s = fixture.init_state_repo("find")
  local _goal, leaf = fixture.root_with_leaf(s)
  fixture.give_spec(s, leaf)
  assert(view.cmd_find(s, "") == 1,
    "no term is a refusal on the verdict line, never a crash")
  assert(view.cmd_find(s, "ranked goal") == 0, "a title hit is a clean read")
  assert(view.cmd_find(s, "Serves the ranked goal above it") == 0,
    "and so is one only the sidecar carries, which cmd_find reads")
end
test_find_reads_the_sidecars_and_refuses_an_empty_term()
