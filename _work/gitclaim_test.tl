#!/usr/bin/env cosmic
-- The claim as a LEASE: who holds it, who has held it, and what it
-- takes to move it. The claim is the lock a take writes and a drop
-- clears; `builders` is the durable record of every holder, which is
-- what makes the sequence auditable after the claim has moved on.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local init_state_repo = fixture.init_state_repo
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

-- The claim moves; the record of who built does not. A drop clears
-- the lease so the next session may take, and `builders` keeps every
-- holder.
local function test_take_appends_a_builder_and_a_drop_keeps_it()
  local s = init_state_repo("builders")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(check.must(store.load(s, leaf)).builders[1] == "session-a",
    "the claiming session is recorded as a builder")

  assert(verbs.cmd_drop(s, leaf, "session-a", "under-specified", false) == 0)
  local dropped = check.must(store.load(s, leaf))
  assert(dropped.claim == "", "the drop clears the lease")
  assert(#dropped.builders == 1 and dropped.builders[1] == "session-a",
    "but not the record of who built")

  assert(verbs.cmd_take(s, leaf, "session-b", 0, false, "") == 0)
  local both = check.must(store.load(s, leaf))
  assert(#both.builders == 2 and both.builders[2] == "session-b",
    "the second holder joins it: " .. table.concat(both.builders, ","))

  -- A session reclaiming an item it already held is already in the
  -- list, and the record carries no repeats.
  assert(verbs.cmd_drop(s, leaf, "session-b", "still under-specified",
      false) == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(#check.must(store.load(s, leaf)).builders == 2,
    "a re-take by an earlier holder adds no second entry")
end
test_take_appends_a_builder_and_a_drop_keeps_it()

-- A live claim is a lease held by one session. Taking it over is
-- legitimate and is never silent: without --force the overwrite is
-- refused, so authorship cannot transfer by accident.
local function test_a_live_claim_needs_force_to_take_over()
  local s = init_state_repo("takeover")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-b", 55, false, "") ~= 0,
    "recording a PR under another session's name is refused")
  local held = check.must(store.load(s, leaf))
  assert(held.claim == "session-a", "and the claim does not move")
  assert(held.pr == 0, "nor does the PR land")

  assert(verbs.cmd_take(s, leaf, "session-b", 55, true,
      "session-a went quiet") == 0, "--force --why performs the takeover")
  local taken = check.must(store.load(s, leaf))
  assert(taken.claim == "session-b", "the lease moved")
  assert(taken.pr == 55, "the PR rode the takeover")
  assert(#taken.builders == 2, "and both holders are on the record: "
    .. table.concat(taken.builders, ","))
end
test_a_live_claim_needs_force_to_take_over()

-- The claim is what joins a diff to its builder, so a handover is a
-- write on a claim: `take --pr` from a session with no claim on a
-- todo item claims and hands over in one act, and the record then
-- names both the PR and the builder.
local function test_a_handover_names_its_builder()
  local s = init_state_repo("handover-claim")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 33, false, "") == 0,
    "take with --pr claims and hands over in one act")
  local it = check.must(store.load(s, leaf))
  assert(it.claim == "session-a", "the builder is on the claim")
  assert(it.pr == 33, "and the diff is joined to the item")
end
test_a_handover_names_its_builder()
