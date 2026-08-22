#!/usr/bin/env cosmic
-- The priority relation and the order derived from it. What these
-- pin is that nothing asserts its own importance: an item's position
-- exists only because a comparison was recorded, transitivity closes
-- what was never asked, a comparison at any height places everything
-- beneath it, and an item no edge reaches has no position at all.

local check = require("cosmic.check")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local prio = require("_work.priority")

local counter = 0

--- A fresh deterministic id; later calls sort later, so creation
--- order is age order exactly as live ksuids behave.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

--- One valid item.
local function make(over: {string: any}): item.Item
  local t: {string: any} = {id = fresh_id(), title = "item"}
  for k, v in pairs(over or {}) do
    t[k] = v
  end
  return check.must(item.decode(t))
end

--- The ids of a list, in order.
local function ids(list: {item.Item}): {string}
  local out: {string} = {}
  for _, i in ipairs(list) do
    out[#out + 1] = i.id
  end
  return out
end

local function test_transitivity_closes_the_untested_pair()
  local c = make({})
  local b = make({beats = c.id})
  local a = make({beats = b.id})
  local items: {item.Item} = {a, b, c}
  local index = prio.index_of(items)
  assert(prio.dominated(index, a.id)[c.id],
    "A > B and B > C settle A against C with nobody asked")
  local at = prio.positions(items)
  local aband = prio.key_of(at, a.id)
  local cband = prio.key_of(at, c.id)
  assert(aband == 2 and cband == 0,
    ("standing follows the closure: %d, %d"):format(aband, cband))
end
test_transitivity_closes_the_untested_pair()

local function test_a_comparison_places_everything_beneath_it()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local mid = make({parent = top.id})
  local leaf = make({parent = mid.id, phase = "ready"})
  local at = prio.positions({lesser, top, mid, leaf})
  assert(prio.is_placed(at, leaf.id),
    "a leaf nobody compared inherits its ancestor's standing")
  local band = prio.key_of(at, leaf.id)
  assert(band == 1, "and inherits the BAND, not a standing of its own: "
    .. tostring(band))
  local _, own = prio.key_of(at, leaf.id)
  assert(own == 0, "it dominates nothing itself: " .. tostring(own))
end
test_a_comparison_places_everything_beneath_it()

local function test_an_item_no_edge_reaches_is_unplaced()
  local lonely = make({})
  local kid = make({parent = lonely.id, phase = "plan"})
  local at = prio.positions({lonely, kid})
  assert(not prio.is_placed(at, lonely.id), "nothing compared it")
  assert(not prio.is_placed(at, kid.id),
    "and an unplaced ancestor places nothing beneath it either")
  local band = prio.key_of(at, kid.id)
  assert(band == -1, "unplaced sorts last: " .. tostring(band))
end
test_an_item_no_edge_reaches_is_unplaced()

local function test_an_edge_the_board_cannot_see_is_not_an_edge()
  local dangling = make({beats = fresh_id()})
  local at = prio.positions({dangling})
  assert(not prio.is_placed(at, dangling.id),
    "an id with no item behind it is a typo, not a comparison")
end
test_an_edge_the_board_cannot_see_is_not_an_edge()

local function test_order_is_band_then_standing_then_age()
  local c = make({})
  local b = make({beats = c.id})
  local a = make({beats = b.id})
  local untouched = make({})
  local items: {item.Item} = {untouched, c, a, b}
  local order = ids(prio.sorted(items, prio.positions(items)))
  assert(order[1] == a.id and order[2] == b.id and order[3] == c.id,
    "the closure orders the compared items")
  assert(order[4] == untouched.id, "and the unplaced one sorts last")
end
test_order_is_band_then_standing_then_age()

local function test_peers_in_one_band_fall_back_to_age()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local older = make({parent = top.id, phase = "plan"})
  local newer = make({parent = top.id, phase = "plan"})
  local items: {item.Item} = {newer, older, top, lesser}
  local order = ids(prio.sorted({newer, older}, prio.positions(items)))
  assert(order[1] == older.id,
    "no comparison separates them, so the oldest still goes first")
end
test_peers_in_one_band_fall_back_to_age()

local function test_a_cycle_is_reported_never_averaged()
  local a = make({})
  local b = make({beats = a.id})
  a.beats = {b.id}
  local problems = prio.cycle_problems({a, b})
  assert(#problems == 2, "both members of the cycle name it: " .. #problems)
  assert(problems[1]:find("ambiguous", 1, true),
    "and the message says what a cycle MEANS: " .. problems[1])
  local at = prio.positions({a, b})
  assert(prio.is_placed(at, a.id),
    "a board holding one still renders rather than refusing to")
end
test_a_cycle_is_reported_never_averaged()

local function test_edge_refusals()
  local a = make({})
  local b = make({beats = a.id})
  local spare = make({})
  local index = prio.index_of({a, b, spare})
  assert(check.must(prio.edge_refusal(index, a.id, a.id))
    :find("itself", 1, true), "nothing outranks itself")
  assert(check.must(prio.edge_refusal(index, b.id, fresh_id()))
    :find("no item", 1, true), "an unknown id is refused")
  assert(check.must(prio.edge_refusal(index, b.id, a.id))
    :find("already outranks", 1, true),
    "a duplicate edge is refused rather than written twice")
  local reverse = prio.edge_refusal(index, a.id, b.id)
  assert(reverse ~= nil and reverse:find("cyclic", 1, true),
    "and the contradicting edge is refused, not silently reversed: "
    .. tostring(reverse))
  assert(prio.edge_refusal(index, a.id, spare.id) == nil,
    "an edge that contradicts nothing is allowed")
end
test_edge_refusals()

-- A blocker is worked to release what it blocks, so it is ordered
-- where that work sits. Without this a blocker can be outranked
-- forever by the very item waiting on it — a deadlock the order
-- creates rather than one the graph holds.
local function test_a_blocker_inherits_the_position_of_what_it_blocks()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local gate = make({parent = lesser.id, phase = "plan"})
  local waiter = make({parent = top.id, phase = "plan",
      blocked_by = gate.id})
  local items: {item.Item} = {lesser, top, gate, waiter}
  local at = prio.positions(items)
  local raw = prio.key_of(at, gate.id)
  local lifted = prio.order_of(at, gate.id)
  local waits = prio.key_of(at, waiter.id)
  assert(raw < waits, ("the recorded band is the lesser one: %d"):format(raw))
  assert(lifted == waits,
    ("the blocker is ordered where its waiter sits: %d vs %d"):format(
      lifted, waits))
  assert(at[gate.id].lifted_from == waiter.id, "and it says who lifted it")
  assert(ids(prio.sorted({gate, waiter}, at))[1] == gate.id,
    "so refinement reaches the blocker before the item it blocks")
end
test_a_blocker_inherits_the_position_of_what_it_blocks()

-- The lift reaches through a chain, so the item at the bottom of a
-- three-deep wait is ordered by the best thing waiting at the top.
local function test_the_lift_reaches_through_a_blocker_chain()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local bottom = make({parent = lesser.id, phase = "plan"})
  local middle = make({parent = lesser.id, phase = "plan",
      blocked_by = bottom.id})
  local head = make({parent = top.id, phase = "plan", blocked_by = middle.id})
  local at = prio.positions({lesser, top, bottom, middle, head})
  local deep = prio.order_of(at, bottom.id)
  assert(deep == prio.key_of(at, head.id),
    ("the chain's foot inherits the head's band: %d"):format(deep))
  local _, _, frees = prio.order_of(at, bottom.id)
  assert(frees == 2, ("two open items wait on it: %d"):format(frees))
end
test_the_lift_reaches_through_a_blocker_chain()

-- Placement is "some comparison reaches this item or an ancestor" and
-- `check` refuses to promote work without it. A blocker edge is not a
-- comparison, so it must not confer one.
local function test_the_lift_never_places_an_unplaced_item()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local nobodys = make({})
  local stray = make({parent = nobodys.id, phase = "plan"})
  local waiter = make({parent = top.id, phase = "plan",
      blocked_by = stray.id})
  local at = prio.positions({lesser, top, nobodys, stray, waiter})
  assert(not prio.is_placed(at, stray.id),
    "a blocker edge is not a comparison and places nothing")
end
test_the_lift_never_places_an_unplaced_item()

-- How much an item unblocks is evidence about throughput, not a
-- judgment about worth: it orders peers a band and a dominance count
-- leave tied, and it never reaches across a band to reorder what
-- somebody compared.
local function test_unblocking_breaks_a_tie_but_never_crosses_a_band()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local low_a = make({parent = lesser.id, phase = "plan"})
  local low_b = make({parent = lesser.id, phase = "plan"})
  local low_c = make({parent = lesser.id, phase = "plan"})
  local leverage = make({parent = lesser.id, phase = "plan"})
  low_a.blocked_by = {leverage.id}
  low_b.blocked_by = {leverage.id}
  low_c.blocked_by = {leverage.id}
  local high = make({parent = top.id, phase = "plan"})
  local items: {item.Item} = {lesser, top, low_a, low_b, low_c, leverage,
    high}
  local at = prio.positions(items)
  local _, _, frees = prio.order_of(at, leverage.id)
  assert(frees == 3, ("three items wait on it: %d"):format(frees))
  local order = ids(prio.sorted({high, leverage}, at))
  assert(order[1] == high.id,
    "the compared item still comes first — leverage never crosses a band")
  local peer = make({parent = lesser.id, phase = "plan"})
  items[#items + 1] = peer
  local within = ids(prio.sorted({peer, leverage}, prio.positions(items)))
  assert(within[1] == leverage.id,
    "but inside the band it beats an older peer that unblocks nothing")
end
test_unblocking_breaks_a_tie_but_never_crosses_a_band()

-- An ended waiter is not waiting: it neither lifts its blocker nor
-- counts toward what that blocker would release.
local function test_an_ended_waiter_neither_lifts_nor_counts()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local gate = make({parent = lesser.id, phase = "plan"})
  local waiter = make({parent = top.id, blocked_by = gate.id,
      resolution = "completed"})
  local at = prio.positions({lesser, top, gate, waiter})
  local lifted, _, frees = prio.order_of(at, gate.id)
  assert(lifted == prio.key_of(at, gate.id),
    ("nothing open waits, so nothing lifts it: %d"):format(lifted))
  assert(frees == 0, ("and nothing counts: %d"):format(frees))
end
test_an_ended_waiter_neither_lifts_nor_counts()

-- A blocker cycle is reported by `_work.health`, never spun on here:
-- the walk terminates and the board still renders.
local function test_a_blocker_cycle_terminates()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local a = make({parent = top.id, phase = "plan"})
  local b = make({parent = top.id, phase = "plan", blocked_by = a.id})
  a.blocked_by = {b.id}
  local at = prio.positions({lesser, top, a, b})
  local _, _, frees = prio.order_of(at, a.id)
  assert(frees == 1, ("the cycle is walked once, not forever: %d"):format(
      frees))
end
test_a_blocker_cycle_terminates()

-- An item nothing has been compared against is not work yet: it is
-- what the triage queue holds and it may still be ended as not
-- planned. Its blocker edge is real, but letting it confer leverage
-- would put untriaged captures in charge of what gets refined.
local function test_an_unplaced_waiter_confers_no_leverage()
  local lesser = make({})
  local top = make({beats = lesser.id})
  local gate = make({parent = top.id, phase = "plan"})
  local capture = make({blocked_by = gate.id})
  local at = prio.positions({lesser, top, gate, capture})
  local _, _, frees = prio.order_of(at, gate.id)
  assert(frees == 0,
    ("an unplaced capture waits, but does not count: %d"):format(frees))
  local placed = make({parent = top.id, phase = "plan",
      blocked_by = gate.id})
  local _, _, counted = prio.order_of(
    prio.positions({lesser, top, gate, capture, placed}), gate.id)
  assert(counted == 1, ("the placed waiter does: %d"):format(counted))
end
test_an_unplaced_waiter_confers_no_leverage()
