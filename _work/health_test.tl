#!/usr/bin/env cosmic
-- The stall detectors are pure over the item list plus caller-supplied
-- ages: staleness never fires without evidence, a blocker cycle is
-- reported by name, and a starved ready column names the deepest open
-- blocker every pull waits behind.

local check = require("cosmic.check")
local flow = require("_work.flow")
local health = require("_work.health")
local item = require("_work.item")
local ksuid = require("_work.ksuid")

local counter = 0

--- A fresh deterministic id; later calls sort later.
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

local function test_staleness_needs_a_claim_and_an_age_past_the_lease()
  local root = make({})
  local claimed = make({parent = root.id, phase = "do", claim = "session-B"})
  local unclaimed = make({parent = root.id, phase = "do"})
  assert(not health.is_stale(claimed, {}),
    "no age recorded never reads as stale")
  assert(not health.is_stale(claimed, {[claimed.id] = health.LEASE_S}),
    "the lease boundary itself still holds")
  assert(health.is_stale(claimed, {[claimed.id] = health.LEASE_S + 1}),
    "past it the claim is stale")
  assert(not health.is_stale(unclaimed, {[unclaimed.id] = health.LEASE_S * 2}),
    "an unclaimed item has no claim to go stale")
  assert(health.stale_hours(claimed, {[claimed.id] = 5 * 60 * 60}) == 5,
    "hours render whole")
end
test_staleness_needs_a_claim_and_an_age_past_the_lease()

local function test_a_blocker_cycle_is_reported_by_name()
  local root = make({})
  local x = make({parent = root.id, phase = "plan"})
  local y = make({parent = root.id, phase = "plan", blocked_by = x.id})
  -- The verb refuses this edge; a race between two checkouts does not.
  x.blocked_by = {y.id}
  local items: {item.Item} = {root, x, y}
  local problems = health.blocker_cycle_problems(items)
  assert(#problems == 2, "both cycle members report: " .. #problems)
  assert(problems[1]:find("returns to itself", 1, true),
    "and the line says what it is: " .. problems[1])
  x.blocked_by = {}
  assert(#health.blocker_cycle_problems(items) == 0,
    "a broken cycle reports nothing")
end
test_a_blocker_cycle_is_reported_by_name()

local function test_chain_root_is_the_deepest_open_blocker()
  local root = make({})
  local bottom = make({parent = root.id, phase = "plan"})
  local middle = make({parent = root.id, phase = "plan",
      blocked_by = bottom.id})
  local top = make({parent = root.id, phase = "ready",
      blocked_by = middle.id})
  local items: {item.Item} = {root, bottom, middle, top}
  local index = flow.by_id(items)
  assert(health.chain_root(index, top).id == bottom.id,
    "the walk bottoms at the free item")
  assert(health.chain_root(index, bottom).id == bottom.id,
    "a free item is its own root")
  -- An ended blocker does not bind, so the chain stops above it.
  bottom.resolution = "completed"
  bottom.phase = ""
  assert(health.chain_root(index, top).id == middle.id,
    "a closed blocker ends the walk")
end
test_chain_root_is_the_deepest_open_blocker()

local function test_starved_ready_reports_only_when_nothing_pulls()
  local root = make({})
  local blocker = make({parent = root.id, phase = "plan"})
  local waiting = make({parent = root.id, phase = "ready",
      blocked_by = blocker.id})
  local free = make({parent = root.id, phase = "ready"})
  local items: {item.Item} = {root, blocker, waiting, free}
  local b = flow.board(items)
  local index = flow.by_id(items)
  local r1, _ = health.starved(b, index, {})
  assert(r1 == nil, "a pullable item means no starvation")
  local only: {item.Item} = {root, blocker, waiting}
  local r2, line = health.starved(flow.board(only), flow.by_id(only), {})
  assert(r2 ~= nil and r2.id == blocker.id,
    "all-blocked names the chain root")
  assert(line:find(blocker.id:sub(1, 8), 1, true)
    and line:find("plan", 1, true),
    "the line carries id and phase: " .. line)
  local none: {item.Item} = {root, blocker}
  local r3, _ = health.starved(flow.board(none), flow.by_id(none), {})
  assert(r3 == nil, "an empty ready is not starved, it is empty")
end
test_starved_ready_reports_only_when_nothing_pulls()
