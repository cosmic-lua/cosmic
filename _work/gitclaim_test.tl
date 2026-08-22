#!/usr/bin/env cosmic
-- The claim as a LEASE: who holds it, who has held it, and what it
-- takes to move it. The claim is the only thing standing between a
-- session and a verdict on its own work, so the rules about who may
-- write it are the review gate's foundation rather than bookkeeping.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local init_state_repo = fixture.init_state_repo
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
