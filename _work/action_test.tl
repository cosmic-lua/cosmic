#!/usr/bin/env cosmic
-- The one next action, case by case: work flows right to left, so an
-- accepted item outranks a review, a review outranks finishing a
-- build, finishing outranks pulling, and only then does intake add
-- anything. The convergence claims — that doing what `next` says
-- always moves the board and drains it — are `converge_test.tl`.

local check = require("cosmic.check")
local act = require("_work.action")
local flow = require("_work.flow")
local health = require("_work.health")
local item = require("_work.item")
local ksuid = require("_work.ksuid")

local type Item = item.Item

local counter = 0

--- A fresh deterministic id; later calls sort later, so creation
--- order is age order exactly as live ksuids behave.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

--- One valid item.
local function make(over: {string: any}): Item
  local t: {string: any} = {id = fresh_id(), title = "item"}
  for k, v in pairs(over or {}) do
    t[k] = v
  end
  return check.must(item.decode(t))
end

--- A placed root: it outranks a spent peer, so everything beneath it
--- has a position.
local function placed_root(items: {Item}): Item
  local spent = make({resolution = "completed"})
  local root = make({beats = spent.id})
  items[#items + 1] = spent
  items[#items + 1] = root
  return root
end

--- A spec map passing the bar for every id given.
local READY < const > = "## Change\nDo this.\n## Non-goals\nNot that.\n"
.. "## Acceptance\n`ci`\n"

local function ready_specs(items: {Item}): act.Specs
  local out: act.Specs = {}
  for _, i in ipairs(items) do
    out[i.id] = READY
  end
  return out
end

local function test_the_ordering_runs_right_to_left()
  local items: {Item} = {}
  local root = placed_root(items)
  local accepted = make({parent = root.id, claim = "who", pr = 1,
      verdict = "accept"})
  local reviewable = make({parent = root.id, claim = "who", pr = 2})
  local building = make({parent = root.id, claim = "me"})
  local fresh = make({parent = root.id})
  items[#items + 1] = accepted
  items[#items + 1] = reviewable
  items[#items + 1] = building
  items[#items + 1] = fresh
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "finish" and a.item.id == accepted.id,
    "the accepted item is the most finished work there is: " .. a.kind)
  accepted.resolution = "completed"
  accepted.claim = ""
  local b = act.next_action(items, specs, "me")
  assert(b.kind == "review" and b.item.id == reviewable.id,
    "then the verdict: " .. b.kind)
  reviewable.verdict = "accept"
  local c = act.next_action(items, specs, "me")
  assert(c.kind == "finish" and c.item.id == reviewable.id,
    "an accept re-enters as the next finish: " .. c.kind)
  reviewable.resolution = "completed"
  reviewable.claim = ""
  local d = act.next_action(items, specs, "me")
  assert(d.kind == "finish" and d.item.id == building.id,
    "then my own build: " .. d.kind)
  building.resolution = "completed"
  building.claim = ""
  local e = act.next_action(items, specs, "me")
  assert(e.kind == "pull" and e.item.id == fresh.id,
    "and only then a pull: " .. e.kind)
end
test_the_ordering_runs_right_to_left()

local function test_a_live_foreign_review_claim_is_stepped_past()
  local items: {Item} = {}
  local root = placed_root(items)
  local first = make({parent = root.id, claim = "b1", pr = 1,
      reviewer = "other"})
  local second = make({parent = root.id, claim = "b2", pr = 2})
  items[#items + 1] = first
  items[#items + 1] = second
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "review" and a.item.id == second.id,
    "a live foreign review claim excludes the diff: " .. a.item.id)
  local stale: health.Ages = {[first.id] = health.REVIEW_LEASE_S + 1}
  local b = act.next_action(items, specs, "me", stale)
  assert(b.kind == "review" and b.item.id == first.id,
    "a stale one is anyone's again, and it is first in queue order")
  local unnamed = act.next_action(items, specs)
  assert(unnamed.kind == "review" and unnamed.item.id == first.id,
    "an unnamed session is stepped past nothing")
end
test_a_live_foreign_review_claim_is_stepped_past()

local function test_anothers_live_build_is_held_a_stale_one_offered()
  local items: {Item} = {}
  local root = placed_root(items)
  local theirs = make({parent = root.id, claim = "other"})
  items[#items + 1] = theirs
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind ~= "finish",
    "a live foreign claim is a builder mid loop: " .. a.kind)
  local stale: health.Ages = {[theirs.id] = health.LEASE_S + 1}
  local b = act.next_action(items, specs, "me", stale)
  assert(b.kind == "finish" and b.item.id == theirs.id,
    "a stale claim is anyone's: " .. b.kind)
  assert(b.reason:find("take it over", 1, true),
    "and the takeover is named, on the record: " .. b.reason)
end
test_anothers_live_build_is_held_a_stale_one_offered()

local function test_rework_returns_to_its_builder_first()
  local items: {Item} = {}
  local root = placed_root(items)
  local sent_back = make({parent = root.id, claim = "builder", pr = 7,
      verdict = "request changes"})
  items[#items + 1] = sent_back
  local specs = ready_specs(items)
  local mine = act.next_action(items, specs, "builder")
  assert(mine.kind == "finish" and mine.item.id == sent_back.id,
    "the builder picks their own rework up: " .. mine.kind)
  assert(mine.reason:find("rework", 1, true), mine.reason)
  local other = act.next_action(items, specs, "someone-else")
  assert(other.kind ~= "finish",
    "a live rework claim holds like any other: " .. other.kind)
end
test_rework_returns_to_its_builder_first()

local function test_pull_skips_what_is_blocked_and_what_misses_the_bar()
  local items: {Item} = {}
  local root = placed_root(items)
  local blocker = make({parent = root.id, claim = "other"})
  local blocked = make({parent = root.id, blocked_by = blocker.id})
  local unrefined = make({parent = root.id})
  local free = make({parent = root.id})
  items[#items + 1] = blocker
  items[#items + 1] = blocked
  items[#items + 1] = unrefined
  items[#items + 1] = free
  local specs = ready_specs(items)
  specs[unrefined.id] = "## Change\nonly this\n"
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "pull" and a.item.id == free.id,
    ("blocked and unrefined items are skipped: %s %s"):format(a.kind,
      a.item and a.item.id or ""))
end
test_pull_skips_what_is_blocked_and_what_misses_the_bar()

local function test_the_doing_bound_suppresses_the_pull()
  local items: {Item} = {}
  local root = placed_root(items)
  for k = 1, flow.DOING_LIMIT do
    items[#items + 1] = make({parent = root.id,
        claim = ("wake-%d"):format(k)})
  end
  local fresh = make({parent = root.id})
  items[#items + 1] = fresh
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind ~= "pull",
    "at the bound nothing new is offered: " .. a.kind)
end
test_the_doing_bound_suppresses_the_pull()

local function test_the_decision_carries_alternates_across_rungs()
  local items: {Item} = {}
  local root = placed_root(items)
  local reviewable = make({parent = root.id, claim = "who", pr = 2})
  local fresh_a = make({parent = root.id})
  local fresh_b = make({parent = root.id})
  items[#items + 1] = reviewable
  items[#items + 1] = fresh_a
  items[#items + 1] = fresh_b
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "review", "the primary is the rightmost rung")
  local alts = a.alternates or {}
  assert(#alts >= 2, "and the list crosses rungs to the pulls: " .. #alts)
  assert(alts[1].kind == "pull",
    "rung order holds within the list: " .. alts[1].kind)
end
test_the_decision_carries_alternates_across_rungs()

local function test_all_blocked_names_the_chain_root()
  local items: {Item} = {}
  local root = placed_root(items)
  local bottom = make({parent = root.id, claim = "other"})
  local waiting = make({parent = root.id, blocked_by = bottom.id})
  items[#items + 1] = bottom
  items[#items + 1] = waiting
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "unblock" and a.item.id == bottom.id,
    ("every takeable item blocked names the chain bottom: %s %s"):format(
      a.kind, a.item and a.item.id:sub(1, 8) or ""))
end
test_all_blocked_names_the_chain_root()

local function test_none_names_the_binding_fact()
  -- The root is deliberately unplaced with an open child, so no
  -- intake rung fires: it is not triage (it has children), nothing is
  -- todo, and it is not a placed root to decompose. What remains is
  -- the fact that binds — another session's live claim.
  local root = make({})
  local theirs = make({parent = root.id, claim = "other"})
  local items: {Item} = {root, theirs}
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "none", "nothing here is mine to move: " .. a.kind)
  assert(a.reason:find("@other", 1, true),
    "and the holder is named, not counted: " .. a.reason)
end
test_none_names_the_binding_fact()
