#!/usr/bin/env cosmic
-- The claim as a LEASE: who holds it, who has held it, what it takes
-- to move it, and what a handover to `check` must name. The claim is
-- the only thing standing between a session and a verdict on its own
-- work, so the rules about who may write it are the review gate's
-- foundation rather than bookkeeping — and correcting one must not
-- cost the item two spurious transitions.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")

local init_state_repo = fixture.init_state_repo
local commits = fixture.commits
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- The claim moves; the record of who built does not. A return clears
-- the lease so the next session may pull, and `builders` keeps every
-- holder — which is what `next` consults to withhold a verdict from
-- whoever wrote the diff.
local function test_claim_appends_a_builder_and_a_return_keeps_it()
  local s = init_state_repo("builders")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(check.must(store.load(s, leaf)).builders[1] == "session-a",
    "the claiming session is recorded as a builder")

  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  local returned = check.must(store.load(s, leaf))
  assert(returned.claim == "", "the return drops the lease")
  assert(#returned.builders == 1 and returned.builders[1] == "session-a",
    "but not the record of who built")

  assert(verbs.cmd_move(s, leaf, "do", "session-b", 0, false, "") == 0)
  local both = check.must(store.load(s, leaf))
  assert(#both.builders == 2 and both.builders[2] == "session-b",
    "the second holder joins it: " .. table.concat(both.builders, ","))

  -- A session reclaiming an item it already held is already in the
  -- list, and the record carries no repeats.
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(#check.must(store.load(s, leaf)).builders == 2,
    "a re-pull by an earlier holder adds no second entry")
end
test_claim_appends_a_builder_and_a_return_keeps_it()

-- A live claim is a lease held by one session. Taking it over is
-- legitimate and is never silent: without --force the overwrite is
-- refused, so authorship cannot transfer by accident.
local function test_a_live_claim_needs_force_to_take_over()
  local s = init_state_repo("takeover")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "do", "session-a", 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "check", "session-b", 55, false, "") ~= 0,
    "moving a claimed item under another session's name is refused")
  local held = check.must(store.load(s, leaf))
  assert(held.claim == "session-a", "and the claim does not move")
  assert(held.phase == "do", "nor does the item")

  assert(verbs.cmd_move(s, leaf, "check", "session-b", 55, true,
      "session-a went quiet") == 0, "--force --why performs the takeover")
  local taken = check.must(store.load(s, leaf))
  assert(taken.claim == "session-b", "the lease moved")
  assert(#taken.builders == 2, "and both holders are on the record: "
    .. table.concat(taken.builders, ","))
end
test_a_live_claim_needs_force_to_take_over()

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
