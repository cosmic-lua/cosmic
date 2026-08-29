#!/usr/bin/env cosmic
-- The verbs that judge an item's spec sidecar: `spec` itself, whose
-- write is a compare-and-swap against the text the caller read, and
-- the spec bar, which asks whether that text says enough to implement
-- from. Both read the same file, so they are tested together, apart
-- from the state verbs in `_work/gitverbs_test.tl`, which judge an
-- item's MOTION.

local check = require("cosmic.check")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local fs = require("cosmic.fs")
local store = require("_work.store")
local fixture = require("_work.fixture")
local verbs = require("_work.gitverbs")
local graph = require("_work.gitgraph")
local view = require("_work.gitview")

local tmpdir = fixture.tmpdir
local READY_SPEC < const > = fixture.READY_SPEC
local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item
local commits = fixture.commits
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- The spec bar judges the item being taken. Another item's broken
-- chain is board health, reported by `status`, never a refusal of a
-- take that has nothing to do with it.
local function test_the_spec_bar_is_the_items_own()
  local s = init_state_repo("readybar")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  -- An unrelated broken chain: work under a parent that is not there.
  local finding = file_item(s, "a finding", "")
  local stray = check.must(store.load(s, finding))
  stray.parent = "3HyArM3A3zHuRxn3VYCvKmUZ7KW"
  assert(store.save(s, stray, "hand-edited parent"))
  local all = check.must(store.list(s))
  assert(#flow.graph_problems(all) > 0, "the board does have a problem")
  assert(view.cmd_check(s, leaf) == 0,
    "a sound item meets the bar while another item is broken")
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "and it may be taken")
  assert(check.must(store.load(s, leaf)).claim == "session-a", "it moved")
end
test_the_spec_bar_is_the_items_own()

-- A hollow spec still refuses, naming the sections it lacks.
local function test_the_spec_bar_still_refuses_a_hollow_spec()
  local s = init_state_repo("hollow")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "no spec, no take")
  assert(check.must(store.load(s, leaf)).claim == "", "it stayed put")
end
test_the_spec_bar_still_refuses_a_hollow_spec()

-- Re-running a mutation that records the same values says so.
local function test_a_no_op_mutation_is_named()
  local s = init_state_repo("noop")
  local _, leaf = root_with_leaf(s)
  local path = fs.join(tmpdir, "ready-spec.md")
  assert(fs.write(path, READY_SPEC))
  assert(verbs.cmd_spec(s, leaf, path) == 0)
  assert(verbs.cmd_spec(s, leaf, path, path) ~= 0,
    "the same spec twice records nothing the second time")
end
test_a_no_op_mutation_is_named()

-- One markdown file under tmpdir, for the spec tests below.
local function spec_file(name: string, body: string): string
  local path = fs.join(tmpdir, name .. ".md")
  assert(fs.write(path, body))
  return path
end

-- `spec` replaces the WHOLE sidecar, so a write naming no base is one
-- that cannot say what it read. Refused, with nothing recorded.
local function test_spec_refuses_a_write_with_no_base()
  local s = init_state_repo("nobase")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_spec(s, leaf, spec_file("nobase-first", READY_SPEC)) == 0,
    "the first spec has nothing to overwrite, so it needs no base")
  local second = spec_file("nobase-second",
    (READY_SPEC:gsub("Not that.", "Rewritten.")))
  local before = commits(s)
  assert(verbs.cmd_spec(s, leaf, second) ~= 0,
    "a second write with no base is last-write-wins")
  assert(store.read_spec(s, leaf) == READY_SPEC, "so the first text stands")
  assert(commits(s) == before, "and nothing was committed")
end
test_spec_refuses_a_write_with_no_base()

-- The base is the text the caller READ. One a later writer already
-- replaced is the concurrent refinement this catches; re-reading the
-- sidecar makes the very same write land.
local function test_spec_refuses_a_stale_base()
  local s = init_state_repo("stalebase")
  local _, leaf = root_with_leaf(s)
  local first = spec_file("stale-first", READY_SPEC)
  assert(verbs.cmd_spec(s, leaf, first) == 0)
  local second = spec_file("stale-second",
    (READY_SPEC:gsub("Not that.", "First edit.")))
  assert(verbs.cmd_spec(s, leaf, second, first) == 0, "the base it read")
  local third = spec_file("stale-third",
    (READY_SPEC:gsub("Not that.", "Second edit.")))
  assert(verbs.cmd_spec(s, leaf, third, first) ~= 0,
    "a base the second write already replaced is stale")
  assert(verbs.cmd_spec(s, leaf, third, fs.join(tmpdir, "gone.md")) ~= 0,
    "and an unreadable base is refused, not taken as empty")
  local current = spec_file("stale-current", store.read_spec(s, leaf))
  assert(verbs.cmd_spec(s, leaf, third, current) == 0,
    "re-reading the sidecar makes the same write land")
  assert(store.read_spec(s, leaf):find("Second edit.", 1, true) ~= nil,
    "carrying the text it meant to write")
end
test_spec_refuses_a_stale_base()

-- A blocker id with no item behind it never blocks, so it reads as
-- "sequenced" and pulls anyway. The spec bar is where that is caught.
local function test_spec_bar_names_a_blocker_that_is_not_an_item()
  local s = init_state_repo("dangling")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local it = check.must(store.load(s, leaf))
  it.blocked_by = {"3HyArM3A3zHuRxn3VYCvKmUZ7KW"}
  assert(store.save(s, it, "hand-edited blocker"))
  local problems = gate.ready_problems(s, check.must(store.load(s, leaf)),
    check.must(store.list(s)))
  assert(#problems == 1 and problems[1]:find("not an item", 1, true),
    "the bar names it: " .. table.concat(problems, "; "))
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "and the take is refused")
end
test_spec_bar_names_a_blocker_that_is_not_an_item()

-- A real blocker refuses the take and names what to finish first;
-- recording the order is `block`'s, and the take frees when it ends.
local function test_a_recorded_blocker_sequences_the_take()
  local s = init_state_repo("mirror")
  local goal, leaf = root_with_leaf(s)
  local blocker = file_item(s, "the one that lands first", goal)
  give_spec(s, leaf)
  assert(graph.cmd_block(s, leaf, blocker, false, "sequenced behind it") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "the recorded order holds the take")
  assert(verbs.cmd_done(s, blocker, "completed", false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "and frees it when the blocker ends")
end
test_a_recorded_blocker_sequences_the_take()
