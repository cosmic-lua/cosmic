#!/usr/bin/env cosmic
-- The verdict verb: the one phase it may end, what a non-accept one
-- files with it, and the head it refuses to judge twice. The scratch
-- board harness is `_work.fixture`.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item
local give_spec = fixture.give_spec
local goal_with_leaf = fixture.goal_with_leaf

-- `check` means "awaiting a planner verdict", so it is the one phase
-- a verdict may end: judging from anywhere else would carry unreviewed
-- work into land past every gate between them.
local function test_verdict_judges_only_what_is_in_check()
  local s = init_state_repo("verdict-phase")
  local _, leaf = goal_with_leaf(s)
  give_spec(s, leaf)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "abc1234", "none: test") ~= 0,
    "a plan item has not been reviewed")
  assert(check.must(store.load(s, leaf)).phase == "plan", "and did not move")
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "abc1234", "none: test") ~= 0,
    "nor has an item still being worked")
  assert(verbs.cmd_move(s, leaf, "check", nil, 7, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 7, "abc1234", "none: test") == 0,
    "from check it lands")
  assert(check.must(store.load(s, leaf)).phase == "land", "in land")
end
test_verdict_judges_only_what_is_in_check()

-- Every non-accept verdict is evidence about why a presumed-ready item
-- was not, and that evidence is lost unless the countermeasure is
-- filed with it. The trailer takes an item id or a reasoned "none".
local function test_a_non_accept_verdict_files_its_countermeasure()
  local s = init_state_repo("enable")
  local goal, leaf = goal_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 5, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa", "") ~= 0,
    "no trailer at all is refused")
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa", "none") ~= 0,
    "a reasonless none is not the grammar")
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa",
      "3HyArM3A3zHuRxn3VYCvKmUZ7KW") ~= 0,
    "nor is the id of an item that does not exist")
  local counter = file_item(s, "the countermeasure", goal, 0, false)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa", counter) == 0,
    "a filed countermeasure passes")
  assert(check.must(store.load(s, leaf)).enable == counter, "and is recorded")
  -- An accept has no bounce to explain, so it carries no trailer.
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 5, "bbb", "") == 0,
    "an accept needs none")
  assert(check.must(store.load(s, leaf)).enable == "",
    "and clears the standing one")
end
test_a_non_accept_verdict_files_its_countermeasure()

-- A verdict judges a head; judging the same one twice says nothing
-- happened in between, which is not a fresh round.
local function test_a_verdict_refuses_a_head_it_already_judged()
  local s = init_state_repo("head")
  local _, leaf = goal_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 6, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 6, "cafe123",
      "none: this item's own spec was the gap") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 6, "cafe123",
      "none: still the same gap") ~= 0,
    "the same head twice has nothing new to judge")
  assert(vrd.cmd_verdict(s, leaf, "accept", 6, "cafe456", "") == 0,
    "a moved head does")
end
test_a_verdict_refuses_a_head_it_already_judged()
