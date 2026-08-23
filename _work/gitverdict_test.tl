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
local root_with_leaf = fixture.root_with_leaf

-- `check` means "awaiting a planner verdict", so it is the one phase
-- a verdict may end: judging from anywhere else would carry unreviewed
-- work into land past every gate between them.
local function test_verdict_judges_only_what_is_in_check()
  local s = init_state_repo("verdict-phase")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "abc1234", "none: test") ~= 0,
    "a backlog item has not been reviewed")
  assert(check.must(store.load(s, leaf)).phase == "backlog",
    "and did not move")
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
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
  local goal, leaf = root_with_leaf(s)
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
  local counter = file_item(s, "the countermeasure", goal, false)
  assert(vrd.cmd_verdict(s, leaf, "request changes", 5, "aaa",
      counter:sub(1, 10)) == 0,
    "an unambiguous prefix names the countermeasure, as ids do everywhere")
  assert(check.must(store.load(s, leaf)).enable == counter,
    "and the FULL id is what gets recorded")
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
  local _, leaf = root_with_leaf(s)
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

-- Builder distance was advice at this end: `next --session` withheld
-- the item and nothing stopped a session reaching for `verdict`
-- directly. Naming yourself as the claimant is what is refused — an
-- unnamed session still works, so every repair path survives.
local function test_verdict_refuses_the_builder()
  local s = init_state_repo("verdict-session")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 11, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 11, "abc1234", "", "session-a") ~= 0,
    "the session that built it cannot accept it")
  assert(check.must(store.load(s, leaf)).phase == "check", "and it does not move")
  assert(vrd.cmd_verdict(s, leaf, "accept", 11, "abc1234", "", "session-b") == 0,
    "another session can")
  assert(check.must(store.load(s, leaf)).phase == "land", "and it lands")
end
test_verdict_refuses_the_builder()

-- Every board commit is authored as one fixed identity, so the subject
-- is the only place the log can record who judged — without it, "no
-- session accepts its own work" is unauditable after the fact.
local function test_verdict_subject_names_the_reviewer()
  local s = init_state_repo("verdict-subject")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 12, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 12, "abc1234", "", "session-b") == 0)
  local events = check.must(store.history(s, leaf))
  assert(events[1].subject:find(" by session-b", 1, true),
    "the reviewer rides in the subject: " .. events[1].subject)

  -- An unnamed verdict is still allowed, and says nothing rather than
  -- claiming an empty reviewer. The return clears the claim, so the
  -- rework handover names its builder again.
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", "session-a", 0, false, "") == 0)
  assert(vrd.cmd_verdict(s, leaf, "accept", 0, "def5678", "") == 0)
  local later = check.must(store.history(s, leaf))
  assert(not later[1].subject:find(" by ", 1, true),
    "an unnamed verdict names nobody: " .. later[1].subject)
end
test_verdict_subject_names_the_reviewer()

-- The PR read is guarded by `store.has_origin`, the same guard
-- `gate.handover_refusal` uses, so a local-only board never reaches
-- for GitHub. That guard is what keeps every test above meaning what
-- it meant — all of them run on local-only boards — and it is pinned
-- here rather than left as a property nothing asserts.
local function test_accept_without_an_origin_still_routes_to_land()
  local s = init_state_repo("verdict-no-origin")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 21, false, "") == 0)
  assert(not store.has_origin(s), "the fixture board has no origin")
  assert(vrd.cmd_verdict(s, leaf, "accept", 21, "abc1234", "",
      "session-b") == 0, "the accept is not refused for want of a PR read")
  local landed = check.must(store.load(s, leaf))
  assert(landed.phase == "land",
    "and routes to land as before: " .. tostring(landed.phase))
  assert(landed.resolution == "", "the item is not ended here")
end
test_accept_without_an_origin_still_routes_to_land()
