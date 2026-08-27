#!/usr/bin/env cosmic
-- The refine claim: the dispatch half of the duplicate-refinement
-- collision. Two sessions handed the same plan item refine it twice
-- and the second write is refused only after the work, so `next`
-- skips a plan item under another session's LIVE refine claim,
-- take-mode writes that claim with the offer, and the claim sheds
-- when the item reaches `ready` — where it belongs to nobody until a
-- session pulls it.

local act = require("_work.action")
local check = require("cosmic.check")
local fixture = require("_work.fixture")
local flow = require("_work.flow")
local health = require("_work.health")
local intake = require("_work.intake")
local prio = require("_work.priority")
local store = require("_work.store")
local take = require("_work.gittake")
local verbs = require("_work.gitverbs")

local init_shared = fixture.init_shared
local init_state_repo = fixture.init_state_repo
local root_with_leaf = fixture.root_with_leaf
local give_spec = fixture.give_spec

--- The pure ingredients the draw reads, from a store's items.
local function board_of(s: store.Store): flow.Board, flow.Index,
  {string: prio.Position}, {flow.Item}
  local all = check.must(store.list(s))
  return flow.board(all), flow.by_id(all), prio.positions(all), all
end

--- Run `fn` with the global print captured, so a test can assert what
--- a verb actually said and not only how it exited. The swap goes
--- through _G because `print` itself is const to the checker.
--- @param fn function The call to capture
--- @return integer The call's exit code
--- @return {string} Every printed line, in order
local function with_output(fn: function(): integer): integer, {string}
  local lines: {string} = {}
  local g = _G as {string: any} -- cast: swapping the global print for capture
  local real = g["print"]
  g["print"] = function(...: any)
    local parts: {string} = {}
    for k = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(k, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local code = fn()
  g["print"] = real
  return code, lines
end

-- A live foreign refine claim is skipped and counted; the same claim
-- past the refine lease is anyone's again; one's own claim and an
-- unnamed session are never skipped.
local function test_refine_skips_a_live_foreign_claim()
  local s = init_state_repo("refine-skip")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "plan", "session-a", 0, false, "") == 0,
    "a same-phase move writes the refine claim")
  local b, index, pos = board_of(s)
  local fresh: health.Ages = {[leaf] = 60}
  local drawn = intake.refinable(b, index, pos, "session-b", fresh)
  assert(drawn.item == nil and drawn.held == 1,
    "a live foreign claim is stepped over, and counted")
  local stale: health.Ages = {[leaf] = health.REFINE_LEASE_S + 1}
  assert(intake.refinable(b, index, pos, "session-b", stale).item ~= nil,
    "past the refine lease the claim is anyone's")
  assert(intake.refinable(b, index, pos, "session-a", fresh).item ~= nil,
    "one's own claim is one's own to keep refining")
  assert(intake.refinable(b, index, pos, "", fresh).item ~= nil,
    "an unnamed session is skipped past nothing")
end
test_refine_skips_a_live_foreign_claim()

-- The intake decision routes around a held item to the next free one
-- and says what it stepped over.
local function test_intake_refines_past_a_held_item()
  local s = init_state_repo("refine-route")
  local root, first = root_with_leaf(s)
  local second = fixture.file_item(s, "a second slice", root)
  assert(verbs.cmd_move(s, first, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, second, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, first, "plan", "session-a", 0, false, "") == 0)
  local b, index, pos, all = board_of(s)
  local ages: health.Ages = {[first] = 60, [second] = 60}
  local action = intake.intake_action(all, b, index, pos, ages, "session-b")
  assert(action ~= nil and action.kind == "refine", "the rung still fires")
  assert(action.item.id == second, "and routes to the free item")
  assert(action.reason:find("1 under refinement elsewhere", 1, true),
    "naming what it stepped over: " .. action.reason)
end
test_intake_refines_past_a_held_item()

-- Take claims the refine it offers, in one call, without recording a
-- builder — a refiner stays eligible to review the eventual build —
-- and a second take by the claimant is still a `took`, writing
-- nothing new: without the own-claim branch, `set_in_place` reports
-- "nothing to record", the no-op reads as a lost claim, and the
-- session is told everything was claimed by somebody else.
local function test_take_claims_a_refine()
  local s = init_state_repo("refine-take")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  assert(take.cmd_take(s, "session-z") == 0)
  local held = check.must(store.load(s, leaf))
  assert(held.phase == "plan" and held.claim == "session-z",
    "the refine claim landed with the offer")
  assert(#(held.builders or {}) == 0,
    "a refine claim records no builder")
  local before = fixture.commits(s)
  local code, lines = with_output(function(): integer
      return take.cmd_take(s, "session-z")
    end)
  assert(code == 0)
  local heard = table.concat(lines, "\n")
  assert(heard:find("took (session-z) refine", 1, true),
    "re-taking one's own refine is heard as a take, not a lost list: "
    .. heard)
  assert(fixture.commits(s) == before,
    "and it writes nothing")
end
test_take_claims_a_refine()

-- The wire from the verbs to the skip: the full ordering
-- (`act.next_action`, the same call `next` and take-mode make), not
-- the intake rung called directly, withholds a taken refine from a
-- second session — while still handing the claimant their own.
local function test_next_withholds_a_taken_refine_from_a_second_session()
  local a, b = init_shared("refine-wire")
  local _, leaf = root_with_leaf(a)
  assert(verbs.cmd_move(a, leaf, "plan", nil, 0, false, "") == 0)
  assert(take.cmd_take(a, "session-a") == 0)
  assert(check.must(store.load(a, leaf)).claim == "session-a",
    "session-a holds the refine")
  assert(store.sync(b))
  local all = check.must(store.list(b))
  local ages: health.Ages = {[leaf] = 60}
  local mine = act.next_action(all, "session-a", ages)
  assert(mine.kind == "refine" and mine.item.id == leaf,
    "the claimant is still handed their own refine")
  local theirs = act.next_action(all, "session-b", ages)
  assert(not (theirs.kind == "refine" and theirs.item ~= nil
      and theirs.item.id == leaf),
    "the second session's next routes around the held item")
end
test_next_withholds_a_taken_refine_from_a_second_session()

-- An arrival into ready sheds the refine claim: ready is nobody's
-- until a session pulls it, and `pullables` has no lease check to
-- free a held item later.
local function test_ready_arrival_clears_the_claim()
  local s = init_state_repo("refine-shed")
  local _, leaf = root_with_leaf(s)
  assert(verbs.cmd_move(s, leaf, "plan", nil, 0, false, "") == 0)
  assert(verbs.cmd_move(s, leaf, "plan", "session-a", 0, false, "") == 0)
  give_spec(s, leaf)
  assert(verbs.cmd_move(s, leaf, "ready", nil, 0, false, "") == 0)
  local it = check.must(store.load(s, leaf))
  assert(it.phase == "ready" and (it.claim or "") == "",
    "the claim sheds at the bar")
end
test_ready_arrival_clears_the_claim()

print("all refine-claim tests passed")
