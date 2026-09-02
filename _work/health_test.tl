#!/usr/bin/env cosmic
-- The stall detectors are pure over the item list plus caller-supplied
-- ages: staleness never fires without evidence, a blocker cycle is
-- reported by name, and a chain walk bottoms at the deepest open
-- blocker a stalled take waits behind.

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
  local claimed = make({parent = root.id, claim = "session-B"})
  local unclaimed = make({parent = root.id})
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

local function test_a_blocker_cycle_is_reported_by_name()
  local root = make({})
  local x = make({parent = root.id})
  local y = make({parent = root.id, blocked_by = x.id})
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

local function test_chain_root_is_the_deepest_open_blocker()
  local root = make({})
  local bottom = make({parent = root.id})
  local middle = make({parent = root.id, blocked_by = bottom.id})
  local top = make({parent = root.id, blocked_by = middle.id})
  local items: {item.Item} = {root, bottom, middle, top}
  local index = flow.by_id(items)
  assert(health.chain_root(index, top).id == bottom.id,
    "the walk bottoms at the free item")
  assert(health.chain_root(index, bottom).id == bottom.id,
    "a free item is its own root")
  -- An ended blocker does not bind, so the chain stops above it.
  bottom.resolution = "completed"
  assert(health.chain_root(index, top).id == middle.id,
    "a closed blocker ends the walk")
end

local function test_review_staleness_runs_on_its_own_shorter_lease()
  local root = make({})
  local reading = make({parent = root.id, claim = "builder", pr = 7,
      reviewer = "review-1"})
  assert(not health.is_review_stale(reading,
      {[reading.id] = health.REVIEW_LEASE_S}),
    "the review lease boundary holds")
  assert(health.is_review_stale(reading,
      {[reading.id] = health.REVIEW_LEASE_S + 1}),
    "past it the diff is anyone's again")
end
