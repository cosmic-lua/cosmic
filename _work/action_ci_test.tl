#!/usr/bin/env cosmic
-- `next`'s CI awareness: a reviewable item whose head is still
-- running, or already red, is never offered — split from
-- `action_test.tl`, which sits against the file cap. The CI state
-- map is exactly the shape `ages` is: read once by the caller
-- (`_work.gh`'s `head_checks`), handed in as plain data, so no test
-- here needs a live GitHub read — the four states are just the four
-- strings `head_checks` can report.

local check = require("cosmic.check")
local act = require("_work.action")
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

local READY < const > = "## Change\nDo this.\n## Non-goals\nNot that.\n"
.. "## Acceptance\n`ci`\n"

local function ready_specs(items: {Item}): act.Specs
  local out: act.Specs = {}
  for _, i in ipairs(items) do
    out[i.id] = READY
  end
  return out
end

-- Green and "none" (a repo with no checks at all) are offered exactly
-- as an item with no CI map at all would be — silence is not the
-- refusal.
local function test_green_and_none_are_offered_as_the_review()
  for _, state in ipairs({"green", "none"}) do
    local items: {Item} = {}
    local root = placed_root(items)
    local reviewable = make({parent = root.id, claim = "who", pr = 2})
    items[#items + 1] = reviewable
    local specs = ready_specs(items)
    local ci: act.CiStates = {[reviewable.id] = state}
    local a = act.next_action(items, specs, "me", nil, "", ci)
    assert(a.kind == "review" and a.item.id == reviewable.id,
      ("state %s should still be offered: %s"):format(state, a.kind))
  end
end

-- A head still running is not yet known either way — refused at
-- `take` for the same reason, and never offered here either. The
-- root is deliberately UNPLACED with an open child, the same shape
-- `action_test.tl`'s own `test_none_names_the_binding_fact` uses, so
-- no intake rung has anything to offer instead: it has children (not
-- triage) and is not a placed root to decompose.
local function test_a_running_head_is_not_offered()
  local root = make({})
  local reviewable = make({parent = root.id, claim = "who", pr = 2})
  local items: {Item} = {root, reviewable}
  local specs = ready_specs(items)
  local ci: act.CiStates = {[reviewable.id] = "running"}
  local a = act.next_action(items, specs, "me", nil, "", ci)
  assert(a.kind ~= "review", "a running head is not offered: " .. a.kind)
  assert(a.kind == "none", "and nothing else fires either: " .. a.kind)
  assert(a.reason:find("ci running", 1, true) ~= nil,
    "the reason names it: " .. a.reason)
end

-- A red head is a decided fact, but the next move is the builder's —
-- so it renders differently from "running" even though neither is
-- offered.
local function test_a_red_head_is_not_offered_and_reads_as_the_builders()
  local root = make({})
  local reviewable = make({parent = root.id, claim = "who", pr = 2})
  local items: {Item} = {root, reviewable}
  local specs = ready_specs(items)
  local ci: act.CiStates = {[reviewable.id] = "red"}
  local a = act.next_action(items, specs, "me", nil, "", ci)
  assert(a.kind ~= "review", "a red head is not offered: " .. a.kind)
  assert(a.reason:find("ci red — builder's", 1, true) ~= nil,
    "the reason names it as the builder's move: " .. a.reason)
end

-- A CI-blocked review never crowds out real work: a pullable todo
-- item is still offered ahead of "nothing to do".
local function test_a_ci_blocked_review_never_holds_a_pull_back()
  local items: {Item} = {}
  local root = placed_root(items)
  local reviewable = make({parent = root.id, claim = "who", pr = 2})
  local fresh = make({parent = root.id})
  items[#items + 1] = reviewable
  items[#items + 1] = fresh
  local specs = ready_specs(items)
  local ci: act.CiStates = {[reviewable.id] = "running"}
  local a = act.next_action(items, specs, "me", nil, "", ci)
  assert(a.kind == "pull" and a.item.id == fresh.id,
    "a pullable item is still offered: " .. a.kind)
end

-- With no CI map at all — the shape a caller with no GitHub reach
-- passes — a reviewable item is offered exactly as it always was.
local function test_no_ci_map_offers_the_review_as_before()
  local items: {Item} = {}
  local root = placed_root(items)
  local reviewable = make({parent = root.id, claim = "who", pr = 2})
  items[#items + 1] = reviewable
  local a = act.next_action(items, ready_specs(items), "me")
  assert(a.kind == "review" and a.item.id == reviewable.id,
    "no CI map is not a refusal: " .. a.kind)
end
