#!/usr/bin/env cosmic
-- The intake half of the ordering: the rungs upstream of a claim.
-- Triage first because it is the cheap decision and the starvable
-- one; refinement — the top of todo, toward the spec bar — can never
-- starve; decomposition of an undriven root comes last.

local check = require("cosmic.check")
local decision = require("_work.decision")
local flow = require("_work.flow")
local intake = require("_work.intake")
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

local READY < const > = "## Change\nDo this.\n## Non-goals\nNot that.\n"
.. "## Acceptance\n`ci`\n"

--- Ask intake directly, over its own inputs.
local function ask(items: {item.Item},
    specs: intake.Specs): decision.Action, string
  local a = intake.intake_action(items, specs, flow.by_id(items),
    prio.positions(items))
  if a == nil then
    return nil, "intake offered nothing"
  end
  return a
end

local function test_triage_outranks_refinement()
  local spent = make({resolution = "completed"})
  local root = make({beats = spent.id})
  local unrefined = make({parent = root.id})
  local capture = make({})
  local items: {item.Item} = {spent, root, unrefined, capture}
  local got = check.must(ask(items, {}))
  assert(got.kind == "triage" and got.item.id == capture.id,
    "a capture drains before anything is refined")
  assert(got.reason:find("await triage", 1, true), got.reason)
end
test_triage_outranks_refinement()

local function test_refine_names_the_top_failing_todo()
  local spent = make({resolution = "completed"})
  local root = make({beats = spent.id})
  local passing = make({parent = root.id})
  local failing = make({parent = root.id})
  local blocked = make({parent = root.id, blocked_by = passing.id})
  local items: {item.Item} = {spent, root, passing, failing, blocked}
  local specs: intake.Specs = {[passing.id] = READY}
  local got = check.must(ask(items, specs))
  assert(got.kind == "refine" and got.item.id == failing.id,
    "the highest-placed unblocked todo item missing the bar is refined")
end
test_refine_names_the_top_failing_todo()

local function test_decompose_names_the_undriven_root()
  local spent = make({resolution = "completed"})
  local driven = make({beats = spent.id})
  local idle = make({})
  driven.beats = {spent.id, idle.id}
  local child = make({parent = driven.id, claim = "who"})
  local items: {item.Item} = {spent, driven, idle, child}
  local got = check.must(ask(items, {[child.id] = READY}))
  assert(got.kind == "intake" and got.item.id == idle.id,
    "the placed root with no live work is decomposed")
end
test_decompose_names_the_undriven_root()

local function test_intake_with_nothing_says_so()
  local spent = make({resolution = "completed"})
  local root = make({beats = spent.id})
  local child = make({parent = root.id, claim = "who"})
  local items: {item.Item} = {spent, root, child}
  local got = check.must(ask(items, {[child.id] = READY}))
  assert(got.kind == "intake" and got.item == nil,
    "every root driven is advice, not a target")
  local empty: {item.Item} = {spent}
  local none = ask(empty, {})
  assert(none == nil, "and a board with no open roots offers nothing")
end
test_intake_with_nothing_says_so()
