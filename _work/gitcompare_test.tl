#!/usr/bin/env cosmic
-- The compare verb: a judgment about which of two items matters more,
-- committed the way every other board fact is. What these pin is the
-- round trip — an edge written on the winner, read back as a position
-- the queues sort by — the one-commit reversal of a direct contrary
-- edge, and the refusals that keep the relation from contradicting
-- itself. The scratch board harness is `_work.fixture`.

local check = require("cosmic.check")
local cmp = require("_work.gitcompare")
local fixture = require("_work.fixture")
local prio = require("_work.priority")
local store = require("_work.store")

local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item

local function test_compare_writes_the_edge_on_the_winner()
  local s = init_state_repo("compare-writes")
  local low = file_item(s, "the lesser outcome", "")
  local high = file_item(s, "the greater outcome", "")
  assert(cmp.cmd_compare(s, high, low) == 0, "the comparison lands")
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

-- A direct contrary edge is REVERSED in one commit — the overturned
-- judgment leaves the log in the same commit that records its
-- replacement — while a contrary conclusion several comparisons built
-- is refused: no single edge can honestly reverse it.
local function test_compare_reverses_direct_refuses_transitive()
  local s = init_state_repo("compare-reverses")
  local low = file_item(s, "the lesser outcome", "")
  local high = file_item(s, "the greater outcome", "")
  assert(cmp.cmd_compare(s, high, low) == 0)
  local before_dup = fixture.commits(s)
  assert(cmp.cmd_compare(s, high, low) == 0,
    "the same edge twice is a no-op, not a duplicate")
  assert(fixture.commits(s) == before_dup, "and it writes nothing")
  local before = fixture.commits(s)
  assert(cmp.cmd_compare(s, low, high) == 0,
    "the direct reverse is a reversal, not a refusal")
  assert(fixture.commits(s) == before + 1,
    "and the reversal is ONE commit over both items")
  assert(#check.must(store.load(s, high)).beats == 0,
    "the overturned edge is gone from the old winner")
  local now = check.must(store.load(s, low))
  assert(#now.beats == 1 and now.beats[1] == high,
    "and the new judgment stands on the new winner")
  assert(cmp.cmd_compare(s, high, high) ~= 0, "nothing outranks itself")
  local mid = file_item(s, "a middle outcome", "")
  assert(cmp.cmd_compare(s, high, mid) == 0)
  assert(cmp.cmd_compare(s, mid, low) ~= 0,
    "low > high > mid stands only transitively over mid > low: refused")
end

local function test_every_comparison_is_one_commit()
  local s = init_state_repo("compare-commits")
  local low = file_item(s, "the lesser outcome", "")
  local high = file_item(s, "the greater outcome", "")
  local before = fixture.commits(s)
  assert(cmp.cmd_compare(s, high, low) == 0)
  assert(fixture.commits(s) == before + 1,
    "one comparison, one commit")
  assert(cmp.cmd_compare(s, high, low) == 0,
    "an edge already present is the state already asked for")
  assert(fixture.commits(s) == before + 1,
    "and a no-op commits nothing")
end

-- The already-recorded case: the board already holds the edge asked
-- for, so `compare` prints store's own "nothing to record" line and
-- exits 0 — not a refusal, the same status a fresh comparison earns.
local function test_compare_of_a_standing_edge_is_a_noop_success()
  local s = init_state_repo("compare-noop")
  local low = file_item(s, "the lesser outcome", "")
  local high = file_item(s, "the greater outcome", "")
  assert(cmp.cmd_compare(s, high, low) == 0)
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local code = cmp.cmd_compare(s, high, low)
  _G.print = old_print
  assert(code == 0, "recording the same edge again succeeds, not refuses")
  assert(table.concat(lines, "\n"):find("nothing to record", 1, true) ~= nil,
    "prints store's own no-op line: " .. table.concat(lines, "\n"))
end
