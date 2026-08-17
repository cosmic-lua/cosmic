#!/usr/bin/env cosmic
-- The item codec is pure: encode omits zero values, decode fills them
-- back in and validates, and the two round-trip through cosmic.literal
-- byte-for-byte. The per-item rules pin the emergent-role invariants a
-- single file can carry: only parented items hold phases or
-- coordination fields, only roots hold ranks, done items hold neither
-- phase nor claim to a slot.

local check = require("cosmic.check")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local literal = require("cosmic.literal")

local ZEROS = ("\0"):rep(16)
local ID = check.must(ksuid.encode(1700000001, ZEROS))
local PARENT = check.must(ksuid.encode(1700000000, ZEROS))

local function base(): {string: any}
  return {id = ID, title = "an item"}
end

local function test_root_round_trips_minimal()
  local it = check.must(item.decode(base()))
  assert(item.is_root(it) and item.is_open(it), "a bare item is an open root")
  local t = item.encode(it)
  local keys = 0
  for _ in pairs(t) do
    keys = keys + 1
  end
  assert(keys == 2, "want only id/title, got " .. keys .. " keys")
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(t))))))
  assert(back.id == ID and back.title == "an item", "round-trips")
end
test_root_round_trips_minimal()

local function test_worked_item_round_trips()
  local t = base()
  t.parent = PARENT
  t.phase = "check"
  t.claim = "session-a"
  t.pr = 456
  t.verdict = "request changes"
  t.verdict_head = "abc1234"
  t.blocked_by = PARENT .. " " .. ID
  local it = check.must(item.decode(t))
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(item.encode(it)))))))
  assert(back.parent == PARENT and back.phase == "check", "position fields")
  assert(back.claim == "session-a" and back.pr == 456, "coordination fields")
  assert(#back.blocked_by == 2 and back.blocked_by[1] == PARENT, "blocked_by")
end
test_worked_item_round_trips()

local function test_roots_hold_ranks_not_phases()
  local goal = base()
  goal.rank = 1
  local g = check.must(item.decode(goal))
  assert(g.rank == 1, "a ranked root decodes")
  local phased = base()
  phased.phase = "plan"
  local bad, err = item.decode(phased)
  assert(bad == nil and err:find("root is never phased", 1, true),
    "a phased root is refused: " .. tostring(err))
  local claimed = base()
  claimed.claim = "session-a"
  local cbad, cerr = item.decode(claimed)
  assert(cbad == nil and cerr:find("not roots", 1, true),
    "a claimed root is refused: " .. tostring(cerr))
end
test_roots_hold_ranks_not_phases()

local function test_parented_items_hold_phases_not_ranks()
  local ranked = base()
  ranked.parent = PARENT
  ranked.rank = 2
  local bad, err = item.decode(ranked)
  assert(bad == nil and err:find("rank belongs to roots", 1, true),
    "a ranked child is refused: " .. tostring(err))
end
test_parented_items_hold_phases_not_ranks()

local function test_done_items_carry_no_phase()
  local t = base()
  t.parent = PARENT
  t.phase = "land"
  t.resolution = "completed"
  local bad, err = item.decode(t)
  assert(bad == nil and err:find("no phase", 1, true),
    "a done phased item is refused: " .. tostring(err))
  t.phase = nil
  local done = check.must(item.decode(t))
  assert(not item.is_open(done), "resolution IS done")
end
test_done_items_carry_no_phase()

local function test_id_discipline()
  local bad, err = item.decode({id = "not-a-ksuid", title = "t"})
  assert(bad == nil and err:find("ksuid", 1, true), "ids are ksuids")
  local blocked = base()
  blocked.blocked_by = "junk"
  local bbad, berr = item.decode(blocked)
  assert(bbad == nil and berr:find("non%-id"), "blocker ids are ksuids: "
    .. tostring(berr))
end
test_id_discipline()
