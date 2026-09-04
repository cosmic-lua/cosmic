#!/usr/bin/env cosmic
-- `next`'s merge-queue awareness: an accepted item whose PR already
-- reports auto-merge armed, or a `mergeable_state` of "queued", is
-- never offered as the head to finish — GitHub is already landing it.
-- Split from `action_test.tl`, which sits against the file cap, the
-- same reason `action_ci_test.tl` exists. The queue map is exactly the
-- shape `ci` is: read once by the caller (`_work.review.is_queued`
-- over a fetched `_work.gh.pull`), handed in as plain data, so no test
-- here needs a live GitHub read.

local check = require("cosmic.check")
local act = require("_work.action")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local review = require("_work.review")

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

local READY < const > = "## Change\nDo this.\n## Non-goals\nNot that.\n"
.. "## Acceptance\n`ci`\n"

local function ready_specs(items: {Item}): act.Specs
  local out: act.Specs = {}
  for _, i in ipairs(items) do
    out[i.id] = READY
  end
  return out
end

-- Auto-merge armed is enough on its own, even with an ordinary
-- `mergeable_state` — the two conditions are an OR. The root is
-- deliberately unplaced with an open child (the same shape
-- `action_ci_test.tl` uses) so no intake rung has anything to offer
-- instead.
local function test_auto_merge_armed_is_not_offered()
  local root = make({})
  local accepted = make({parent = root.id, claim = "who", pr = 2,
      verdict = "accept"})
  local items: {Item} = {root, accepted}
  local specs = ready_specs(items)
  local p: review.Pull = {number = 2, auto_merge = true,
    mergeable_state = "clean"}
  local queue: act.QueueStates = {[accepted.id] = review.is_queued(p)}
  local a = act.next_action(items, specs, "me", nil, "", nil, queue)
  assert(a.kind ~= "finish", "an armed auto-merge is not offered: " .. a.kind)
  assert(a.kind == "none", "and nothing else fires either: " .. a.kind)
  assert(a.reason:find("queued", 1, true) ~= nil,
    "the reason names it: " .. a.reason)
end

-- `mergeable_state == "queued"` alone, with no auto-merge field set at
-- all, is the other half of the OR: the repo's merge queue took it.
local function test_mergeable_state_queued_is_not_offered()
  local root = make({})
  local accepted = make({parent = root.id, claim = "who", pr = 3,
      verdict = "accept"})
  local items: {Item} = {root, accepted}
  local specs = ready_specs(items)
  local p: review.Pull = {number = 3, mergeable_state = "queued"}
  local queue: act.QueueStates = {[accepted.id] = review.is_queued(p)}
  local a = act.next_action(items, specs, "me", nil, "", nil, queue)
  assert(a.kind ~= "finish", "a queued mergeable_state is not offered")
end

-- Neither condition holds: the ordinary "accepted, awaiting merge"
-- head is offered exactly as it always was.
local function test_without_either_it_is_offered_as_the_ordinary_finish()
  local items: {Item} = {}
  local root = placed_root(items)
  local accepted = make({parent = root.id, claim = "who", pr = 4,
      verdict = "accept"})
  items[#items + 1] = accepted
  local specs = ready_specs(items)
  local p: review.Pull = {number = 4, mergeable_state = "clean"}
  local queue: act.QueueStates = {[accepted.id] = review.is_queued(p)}
  local a = act.next_action(items, specs, "me", nil, "", nil, queue)
  assert(a.kind == "finish" and a.item.id == accepted.id,
    "an unqueued accept is still the head to finish: " .. a.kind)
end

-- A queued accept never crowds out real work: a pullable todo item is
-- still offered ahead of "nothing to do" — `next` falls through to it
-- instead of stalling on an unactionable head.
local function test_a_queued_accept_never_holds_a_pull_back()
  local items: {Item} = {}
  local root = placed_root(items)
  local accepted = make({parent = root.id, claim = "who", pr = 5,
      verdict = "accept"})
  local fresh = make({parent = root.id})
  items[#items + 1] = accepted
  items[#items + 1] = fresh
  local specs = ready_specs(items)
  local queue: act.QueueStates = {[accepted.id] = true}
  local a = act.next_action(items, specs, "me", nil, "", nil, queue)
  assert(a.kind == "pull" and a.item.id == fresh.id,
    "a pullable item is still offered: " .. a.kind)
end

-- With no queue map at all — the shape a caller with no GitHub reach
-- passes — an accepted item is offered exactly as it always was.
local function test_no_queue_map_offers_the_finish_as_before()
  local items: {Item} = {}
  local root = placed_root(items)
  local accepted = make({parent = root.id, claim = "who", pr = 6,
      verdict = "accept"})
  items[#items + 1] = accepted
  local a = act.next_action(items, ready_specs(items), "me")
  assert(a.kind == "finish" and a.item.id == accepted.id,
    "no queue map is not a refusal: " .. a.kind)
end
