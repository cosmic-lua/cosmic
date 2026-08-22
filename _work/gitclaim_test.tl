#!/usr/bin/env cosmic
-- The handover to `check` and the claim it must name. The claim is the
-- only thing standing between a session and a verdict on its own work,
-- so who may write it, and when, is the review gate's foundation
-- rather than bookkeeping — and correcting one must not cost the item
-- two spurious transitions.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local commits = fixture.commits
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- The reviewer follows the pr field to the diff, and so does the
-- landing step that reads it back, so the handover must name one.
local function test_check_refuses_a_handover_with_no_pr()
  local s = init_state_repo("check-pr")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") ~= 0,
    "a handover naming no PR is refused")
  assert(check.must(store.load(s, leaf)).phase == "do", "and does not move")
  assert(verbs.cmd_move(s, leaf, "check", nil, 99, false, "") == 0)
  -- Rework returns to `do` and comes back on the SAME PR, already
  -- recorded, so the second handover needs no --pr of its own.
  assert(vrd.cmd_verdict(s, leaf, "request changes", 0, "abc1234", "none: test") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") == 0,
    "the recorded PR carries the rework back")
end
test_check_refuses_a_handover_with_no_pr()

-- The claim is what `next` reads to withhold a verdict from the item's
-- builder, so a handover naming nobody hands the diff to everyone.
-- Rework is where this bites: a second session taking it over must say
-- so, and correcting that must not need a phase round trip.
local function test_check_handover_names_its_builder()
  local s = init_state_repo("handover-claim")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 33, false, "") ~= 0,
    "an unclaimed item cannot be handed over")
  assert(check.must(store.load(s, leaf)).phase == "do", "and does not move")
  assert(verbs.cmd_move(s, leaf, "check", "session-a", 33, false, "") == 0,
    "--claim names the builder and the handover goes through")
  assert(check.must(store.load(s, leaf)).claim == "session-a", "recorded")
end
test_check_handover_names_its_builder()

-- A same-phase move used to exit 0 having written nothing, so the only
-- way to correct a claim was a leftward-then-rightward round trip that
-- writes two transitions a flow instrument reads as real dwell.
local function test_same_phase_move_applies_its_flags()
  local s = init_state_repo("same-phase")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", nil, 44, false, "") == 0)

  local before = commits(s)
  assert(verbs.cmd_move(s, leaf, "check", "session-b", 0, false, "") == 0,
    "a same-phase move with a field to set writes it")
  local fixed = check.must(store.load(s, leaf))
  assert(fixed.claim == "session-b", "the claim was corrected in place")
  assert(fixed.phase == "check", "without a phase change")
  assert(fixed.pr == 44, "and the PR it did not name is untouched")
  assert(commits(s) == before + 1, "one mutation, one commit")

  assert(verbs.cmd_move(s, leaf, "check", nil, 0, false, "") ~= 0,
    "with nothing to set it still refuses")
  assert(commits(s) == before + 1, "and writes nothing")
end
test_same_phase_move_applies_its_flags()
