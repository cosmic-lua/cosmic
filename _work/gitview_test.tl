#!/usr/bin/env cosmic
-- The read verbs render the board without mutating it: what `status`
-- reports as health, what `tree` calls each node, and what `next`
-- names. Their output is what a session reads to decide, so the words
-- are the contract — asserted here on the pure reports the `cmd_*`
-- wrappers print. What `show` prints for one item is
-- `_work/gitshow_test.tl`; the one case that spans both, a repo mark
-- rendered by three reports at once, stays here.

local check = require("cosmic.check")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local fixture = require("_work.fixture")
local show = require("_work.gitshow")
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
local FRESH < const > = fresh_id()
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
--- with one child in flight and one fresh todo leaf.
local function board_items(): {item.Item}
  return {
    check.must(item.decode({id = GOAL, title = "a goal", beats = LESSER})),
    check.must(item.decode({id = CONTAINER, title = "a container",
          parent = GOAL})),
    check.must(item.decode({id = LEAF, title = "a leaf", parent = CONTAINER,
          claim = "session-a", pr = 42})),
    check.must(item.decode({id = FRESH, title = "a fresh leaf",
          parent = GOAL})),
    check.must(item.decode({id = LESSER, title = "a lesser outcome"})),
  }
end

--- A spec map where every open item passes the bar, so `pullable`
--- marks are about state rather than missing sections.
local function full_specs(): {string: string}
  local out: {string: string} = {}
  for _, i in ipairs(board_items()) do
    out[i.id] = fixture.READY_SPEC
  end
  return out
end

local function test_status_renders_doing_against_the_bound()
  local lines, verdict = view.status_report(board_items(), full_specs())
  assert(has(lines, "^doing  1/10$"), table.concat(lines, "\n"))
  assert(has(lines, "%[review%]"), "the substate shows")
  assert(has(lines, "@session%-a"), "so does the claim")
  assert(has(lines, "pr:42"), "and the PR")
  assert(has(lines, "^todo   1 %(1 pullable%)$"),
    "todo renders its depth and its pullable count: "
    .. table.concat(lines, "\n"))
  assert(has(lines, FRESH:sub(1, 8) .. " a fresh leaf %[pullable%]"),
    "the top of todo shows its marks: " .. table.concat(lines, "\n"))
  assert(verdict == "doing 1/10", verdict)
end
test_status_renders_doing_against_the_bound()

local function test_status_names_graph_problems()
  local items = board_items()
  items[#items + 1] = check.must(item.decode({id = fresh_id(),
        title = "an orphan", parent = fresh_id()}))
  local lines, verdict = view.status_report(items, full_specs())
  assert(has(lines, "graph: "),
    "a broken chain is board health: " .. table.concat(lines, "\n"))
  assert(verdict:find("1 graph problem(s)", 1, true), verdict)
end
test_status_names_graph_problems()

local function test_status_reports_the_bound_binding()
  local items = board_items()
  for k = 1, 10 do
    items[#items + 1] = check.must(item.decode({id = fresh_id(),
          title = "more", parent = CONTAINER,
          claim = ("wake-%d"):format(k)}))
  end
  local _, verdict = view.status_report(items, full_specs())
  assert(verdict:find("bound: doing is at 11/10", 1, true), verdict)
end
test_status_reports_the_bound_binding()

local function test_tree_tags_nodes_by_role_and_state()
  local lines, verdict = view.tree_report(board_items())
  assert(has(lines, "^%[>1%] " .. GOAL:sub(1, 8) .. " a goal$"),
    "a placed root leads with what it outranks: " .. table.concat(lines, "\n"))
  assert(has(lines, CONTAINER:sub(1, 8) .. " %[container%]"),
    "an item with an open child is a container")
  assert(has(lines, LEAF:sub(1, 8) .. " %[review%]"),
    "an in-flight leaf shows its substate: " .. table.concat(lines, "\n"))
  assert(has(lines, FRESH:sub(1, 8) .. " %[todo%]"),
    "a fresh leaf is todo: " .. table.concat(lines, "\n"))
  assert(verdict == "2 organizing root(s), 0 item(s) awaiting triage", verdict)
end
test_tree_tags_nodes_by_role_and_state()

local function test_tree_marks_a_root_nothing_is_driving()
  local only_root: {item.Item} = {
    check.must(item.decode({id = GOAL, title = "a goal", beats = LESSER})),
    check.must(item.decode({id = LESSER, title = "a lesser outcome"})),
    check.must(item.decode({id = FRESH, title = "a capture"})),
  }
  local lines, verdict = view.tree_report(only_root)
  assert(has(lines, "%(no live work%)"), table.concat(lines, "\n"))
  assert(has(lines, "^triage " .. FRESH:sub(1, 8)),
    "an unplaced capture queues below: " .. table.concat(lines, "\n"))
  assert(verdict:find("1 item(s) awaiting triage", 1, true), verdict)
end
test_tree_marks_a_root_nothing_is_driving()

local function test_next_names_one_action_and_its_rule()
  local report = view.next_report(board_items(), full_specs())
  assert(report:find("review", 1, true)
    and report:find(LEAF:sub(1, 8), 1, true),
    "a PR awaiting a verdict is judged before anything is pulled: "
    .. report)
  assert(report:find("—", 1, true),
    "and the rule that chose it is stated: " .. report)
end
test_next_names_one_action_and_its_rule()

-- Cross-repo work is visible exactly where it was invisible: `show`
-- prints a `repo:` line, and the queue/tree reports append
-- ` [owner/name]` to the item's line. The default (empty `repo`) is
-- silent — a same-repo item reads the same as it did before this field
-- existed.
local function test_repo_is_rendered_in_show_status_and_tree()
  local all = board_items()
  local scoped = check.must(item.decode({
        id = fresh_id(), title = "a cosmopolitan-side slice",
        parent = CONTAINER, claim = "session-b",
        repo = "whilp/cosmopolitan"}))
  all[#all + 1] = scoped

  local show_lines = show.show_report(scoped, all, "", {})
  assert(has(show_lines, "^repo: whilp/cosmopolitan$"),
    "show prints a repo line: " .. table.concat(show_lines, "\n"))

  local status_lines = view.status_report(all, full_specs())
  assert(has(status_lines, "%[whilp/cosmopolitan%]"),
    "status marks the item with its repo: " .. table.concat(status_lines, "\n"))
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

  local default_show = show.show_report(all[3], all, "", {})
  assert(not has(default_show, "^repo:"),
    "an item with no repo prints no repo line: "
    .. table.concat(default_show, "\n"))
end
test_repo_is_rendered_in_show_status_and_tree()

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
    [CONTAINER] = "## Change\n   serves the widget pipeline\nand nothing else\n",
  }
  local titled, tverdict = view.find_report(searchable_items(), specs, "a leaf")
  assert(#titled == 1, table.concat(titled, "\n"))
  assert(has(titled, "^" .. LEAF:sub(1, 8) .. " %[review%] a leaf$"),
    table.concat(titled, "\n"))
  assert(tverdict == "1 item(s) matching \"a leaf\"", tverdict)
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
  local specs: {string: string} = {[FRESH] = "The WIDGET again\n"}
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
  assert(#lines == 1 and has(lines, dotted:sub(1, 8) .. " %[todo%] "),
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
  assert(view.cmd_find(s, "workable slice") == 0, "a title hit is a clean read")
  assert(view.cmd_find(s, "Do exactly this") == 0,
    "and so is one only the sidecar carries, which cmd_find reads")
end
test_find_reads_the_sidecars_and_refuses_an_empty_term()
