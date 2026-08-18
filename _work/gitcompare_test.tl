#!/usr/bin/env cosmic
-- The compare verb: a judgment about which of two items matters more,
-- committed the way every other board fact is. What these pin is the
-- round trip — an edge written on the winner, read back as a position
-- the queues sort by — and the refusals that keep the relation from
-- contradicting itself. The scratch board harness is `_work.fixture`.

local check = require("cosmic.check")
local cmp = require("_work.gitcompare")
local fixture = require("_work.fixture")
local prio = require("_work.priority")
local store = require("_work.store")

local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item

local function test_compare_writes_the_edge_on_the_winner()
  local s = init_state_repo("compare-writes")
  local low = file_item(s, "the lesser outcome", "", false)
  local high = file_item(s, "the greater outcome", "", false)
  assert(cmp.cmd_compare(s, high, low, false) == 0, "the comparison lands")
  local winner = check.must(store.load(s, high))
  assert(#winner.beats == 1 and winner.beats[1] == low,
    "the edge is on the winner and names the loser")
  local loser = check.must(store.load(s, low))
  assert(#loser.beats == 0, "and the loser records nothing")
  local at = prio.positions(check.must(store.list(s)))
  assert(prio.is_placed(at, low) and prio.is_placed(at, high),
    "both ends of a comparison have a position")
  local hband = prio.key_of(at, high)
  local lband = prio.key_of(at, low)
  assert(hband > lband,
    ("the winner outranks: %d vs %d"):format(hband, lband))
end
test_compare_writes_the_edge_on_the_winner()

local function test_compare_refuses_a_contradiction()
  local s = init_state_repo("compare-refuses")
  local low = file_item(s, "the lesser outcome", "", false)
  local high = file_item(s, "the greater outcome", "", false)
  assert(cmp.cmd_compare(s, high, low, false) == 0)
  assert(cmp.cmd_compare(s, high, low, false) ~= 0,
    "the same edge twice is refused rather than duplicated")
  assert(cmp.cmd_compare(s, low, high, false) ~= 0,
    "and the reverse is refused rather than silently overturning it")
  local still = check.must(store.load(s, high))
  assert(#still.beats == 1, "the standing judgment is untouched")
  assert(cmp.cmd_compare(s, high, high, false) ~= 0,
    "nothing outranks itself")
end
test_compare_refuses_a_contradiction()

-- Overturning a judgment is two commits, both of them in the log:
-- the earlier comparison is data, not a draft to be edited.
local function test_uncompare_frees_the_reverse()
  local s = init_state_repo("compare-uncompare")
  local low = file_item(s, "the lesser outcome", "", false)
  local high = file_item(s, "the greater outcome", "", false)
  assert(cmp.cmd_compare(s, high, low, false) == 0)
  assert(cmp.cmd_compare(s, high, low, true) == 0, "the edge drops")
  assert(#check.must(store.load(s, high)).beats == 0, "and is gone")
  assert(cmp.cmd_compare(s, high, low, true) ~= 0,
    "dropping an edge that is not there is refused")
  assert(cmp.cmd_compare(s, low, high, false) == 0,
    "with nothing standing, the reverse may now be recorded")
end
test_uncompare_frees_the_reverse()

local function test_every_comparison_is_one_commit()
  local s = init_state_repo("compare-commits")
  local low = file_item(s, "the lesser outcome", "", false)
  local high = file_item(s, "the greater outcome", "", false)
  local before = fixture.commits(s)
  assert(cmp.cmd_compare(s, high, low, false) == 0)
  assert(fixture.commits(s) == before + 1,
    "one comparison, one commit")
  assert(cmp.cmd_compare(s, low, high, false) ~= 0)
  assert(fixture.commits(s) == before + 1,
    "and a refused one commits nothing")
end
test_every_comparison_is_one_commit()
