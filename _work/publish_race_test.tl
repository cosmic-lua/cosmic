#!/usr/bin/env cosmic
-- The lost-race contract end to end, through real verbs: a mutation
-- whose guards were decided against pre-race state is never replayed
-- onto the merged board. The two shapes that used to slip through a
-- clean rebase — reciprocal blocks landing a cycle, and the last two
-- children of one container closing at once with nobody re-phasing
-- the parent — are refused with LOST_RACE, and the RE-RUN, deciding
-- afresh against the merged state, does the right thing the stale
-- run could not see.

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local graph = require("_work.gitgraph")
local health = require("_work.health")
local item = require("_work.item")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local init_shared = fixture.init_shared
local file_item = fixture.file_item

-- Reciprocal `block` from two checkouts used to merge cleanly and
-- land a cycle no verb's own check ever saw. Now the loser is
-- refused with LOST_RACE, and its re-run — reading the winner's edge
-- — refuses as the deadlock it is. No cycle at any point.
local function test_a_lost_block_race_cannot_land_a_cycle()
  local a, b = init_shared("race-block")
  local x = file_item(a, "x, the one that waits", "")
  local y = file_item(a, "y, the one it waits on", "")
  assert(store.sync(b))

  assert(graph.cmd_block(a, x, y, false, "x needs y's contract") == 0)
  -- b's read predates a's edge, exactly the reciprocal-block race.
  assert(graph.cmd_block(b, y, x, false, "y needs x's contract") ~= 0,
    "the losing block is refused, not replayed")
  local after = check.must(store.list(b))
  assert(#health.blocker_cycle_problems(after) == 0,
    "no cycle landed anywhere")
  -- The re-run decides against the merged board: the edge would
  -- deadlock both, and the verb's own guard says so.
  assert(graph.cmd_block(b, y, x, false, "y needs x's contract") ~= 0,
    "the re-run meets the cycle guard")
  assert(#(check.must(store.load(b, y)).blocked_by or {}) == 0,
    "and writes no edge")
  assert(#(check.must(store.load(b, x)).blocked_by or {}) == 1,
    "the winner's edge stands alone")
end
test_a_lost_block_race_cannot_land_a_cycle()

-- Concurrent `done` of a container's last two children: each session
-- read the other's child as still open, so neither computed the
-- parent's return, and the parent sat open, workable and unphased.
-- Now the loser re-runs against the merged state, sees it is closing
-- the LAST open child, and the parent comes back to backlog in the
-- same commit.
local function test_a_lost_done_race_rephases_the_parent()
  local a, b = init_shared("race-done")
  local root = file_item(a, "an outcome", "")
  local parent = file_item(a, "a slice being decomposed", root)
  local c1 = file_item(a, "the first child", parent)
  local c2 = file_item(a, "the second child", parent)
  assert(store.sync(b))

  assert(verbs.cmd_done(a, c1, "completed", false, "") == 0)
  -- b still sees c1 open, so its stale run would not re-phase the
  -- parent — the miss that used to merge cleanly.
  assert(verbs.cmd_done(b, c2, "completed", false, "") ~= 0,
    "the losing done is refused, not replayed")
  assert(item.is_open(check.must(store.load(b, c2))),
    "the dropped close is undone whole")
  -- The re-run closes the last open child and brings the parent back.
  assert(verbs.cmd_done(b, c2, "completed", false, "") == 0,
    "the re-run lands against the merged state")
  assert(store.sync(a))
  assert(not item.is_open(check.must(store.load(a, c2))), "c2 is closed")
  assert(check.must(store.load(a, parent)).phase == "backlog",
    "the parent returns to the board instead of stranding unphased")
end
test_a_lost_done_race_rephases_the_parent()

print("all publish-race tests passed")
