#!/usr/bin/env cosmic
-- What the one next action is. There is one worker and one ordering,
-- and that ordering is the system's central claim: finishing beats
-- starting, all the way down the board. The claim filter is what
-- makes it safe to ask when several sessions run at once — and what
-- keeps a session from reviewing what it built.

local check = require("cosmic.check")
local flow = require("_work.flow")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local act = require("_work.action")

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

local function test_finishing_beats_pulling()
  local goal = make({})
  local ready = make({parent = goal.id, phase = "ready"})
  local doing = make({parent = goal.id, phase = "do"})
  local landing = make({parent = goal.id, phase = "land"})
  local items: {item.Item} = {goal, ready, doing, landing}
  local action = act.next_action(items)
  assert(action.kind == "finish" and action.item.id == landing.id,
    "land first, got " .. action.kind)
end
test_finishing_beats_pulling()

local function test_blocked_ready_items_are_not_pulled()
  local goal = make({})
  local blocker = make({parent = goal.id, phase = "plan"})
  local blocked = make({parent = goal.id, phase = "ready",
      blocked_by = blocker.id})
  local free = make({parent = goal.id, phase = "ready"})
  local items: {item.Item} = {goal, blocker, blocked, free}
  local action = act.next_action(items)
  assert(action.kind == "pull" and action.item.id == free.id,
    "the blocked item is skipped for the free one: " .. action.kind)
end
test_blocked_ready_items_are_not_pulled()

local function test_another_sessions_claim_is_not_handed_over()
  local goal = make({})
  local theirs = make({parent = goal.id, phase = "do", claim = "session-A"})
  local ready = make({parent = goal.id, phase = "ready"})
  local items: {item.Item} = {goal, theirs, ready}
  local mine = act.next_action(items, "session-B")
  assert(mine.kind == "pull" and mine.item.id == ready.id,
    "B pulls rather than finishing A's claim: " .. mine.kind)
  local theirs_again = act.next_action(items, "session-A")
  assert(theirs_again.kind == "finish" and theirs_again.item.id == theirs.id,
    "A finishes its own claim: " .. theirs_again.kind)
end
test_another_sessions_claim_is_not_handed_over()

local function test_an_unclaimed_do_item_is_anyones()
  local goal = make({})
  local loose = make({parent = goal.id, phase = "do"})
  local items: {item.Item} = {goal, loose}
  local action = act.next_action(items, "session-B")
  assert(action.kind == "finish" and action.item.id == loose.id,
    "an unclaimed do item is finishable by anyone: " .. action.kind)
end
test_an_unclaimed_do_item_is_anyones()

local function test_an_unnamed_session_skips_nothing_but_says_whose()
  local goal = make({})
  local theirs = make({parent = goal.id, phase = "do", claim = "session-A"})
  local items: {item.Item} = {goal, theirs}
  local action = act.next_action(items)
  assert(action.kind == "finish" and action.item.id == theirs.id,
    "a session that names nothing is held back by nothing")
  assert(action.reason:find("claimed by session-A", 1, true),
    "and is told whose it is: " .. action.reason)
end
test_an_unnamed_session_skips_nothing_but_says_whose()

local function test_held_work_with_nothing_to_pull_says_so()
  local goal = make({})
  local theirs = make({parent = goal.id, phase = "do", claim = "session-A"})
  local items: {item.Item} = {goal, theirs}
  local action = act.next_action(items, "session-B")
  assert(action.kind == "none", "nothing for B to do: " .. action.kind)
  assert(action.reason:find("claimed by other sessions", 1, true),
    "and the reason names why: " .. action.reason)
  -- A claim has no expiry, so an abandoned one strands its item and
  -- everything waiting on it until a person takes it back. The reason
  -- has to say which item and whose, not just how many.
  assert(action.reason:find(theirs.id:sub(1, 8) .. " @session-A", 1, true),
    "and which item is held, by whom: " .. action.reason)
end
test_held_work_with_nothing_to_pull_says_so()

-- Placement is what separates the two: an unplaced capture is
-- triage, a placed root nothing drives is intake.
-- The phased half outranks all of this, so the live work here is held
-- by ANOTHER session: that is what leaves the intake half to decide.
local function test_triage_then_intake()
  local idle = make({})
  local driven = make({beats = idle.id})
  local worked = make({parent = driven.id, phase = "do", claim = "session-B"})
  local captured = make({})
  local items: {item.Item} = {idle, driven, worked, captured}
  local action = act.next_action(items, "session-A")
  assert(action.kind == "triage" and action.item.id == captured.id,
    "an unplaced capture outranks intake: " .. action.kind)
  local drained: {item.Item} = {idle, driven, worked}
  local intake = act.next_action(drained, "session-A")
  assert(intake.kind == "intake" and intake.item.id == idle.id,
    "the placed root with no live work: " .. intake.kind)
end
test_triage_then_intake()

-- One worker builds and reviews, so the distance between the two is
-- no longer a model boundary — it is the claim, which survives the
-- move into `check` and says who did the work.
local function test_a_session_is_not_handed_its_own_work_to_review()
  local root = make({})
  local mine = make({parent = root.id, phase = "check", pr = 7,
      claim = "session-A"})
  local items: {item.Item} = {root, mine}
  local same = act.next_action(items, "session-A")
  assert(same.kind ~= "review",
    "the session that built it is not handed the verdict: " .. same.kind)
  assert(same.reason:find("built by this session", 1, true), same.reason)
  local other = act.next_action(items, "session-B")
  assert(other.kind == "review" and other.item.id == mine.id,
    "another session reviews it: " .. other.kind)
  local anon = act.next_action(items)
  assert(anon.kind == "review",
    "a session that names nothing has no distance to keep: " .. anon.kind)
end
test_a_session_is_not_handed_its_own_work_to_review()

-- Skipping its own review must not strand the session: the ordering
-- carries on to the left, and it takes the next thing it MAY do.
local function test_skipping_its_own_review_falls_through()
  local root = make({})
  local mine = make({parent = root.id, phase = "check", pr = 7,
      claim = "session-A"})
  local ready = make({parent = root.id, phase = "ready"})
  local items: {item.Item} = {root, mine, ready}
  local action = act.next_action(items, "session-A")
  assert(action.kind == "pull" and action.item.id == ready.id,
    "it pulls instead of stalling: " .. action.kind)
end
test_skipping_its_own_review_falls_through()

local function test_verdicts_come_before_refinement()
  local goal = make({})
  local planning = make({parent = goal.id, phase = "plan"})
  local checking = make({parent = goal.id, phase = "check", pr = 7})
  local items: {item.Item} = {goal, planning, checking}
  local action = act.next_action(items)
  assert(action.kind == "review" and action.item.id == checking.id,
    "verdicts come before refinement: " .. action.kind)
end
test_verdicts_come_before_refinement()

local function test_an_over_bound_triage_queue_outranks_refining()
  local goal = make({})
  local planning = make({parent = goal.id, phase = "plan"})
  local items: {item.Item} = {goal, planning}
  local oldest: item.Item = nil
  for _ = 1, flow.TRIAGE_LIMIT do
    local finding = make({})
    oldest = oldest or finding
    items[#items + 1] = finding
  end
  local under = act.next_action(items)
  assert(under.kind == "refine" and under.item.id == planning.id,
    "at the bound, ready has slack and refinement still wins: " .. under.kind)
  items[#items + 1] = make({})
  local over = act.next_action(items)
  assert(over.kind == "triage" and over.item.id == oldest.id,
    "past the bound, the oldest finding is drained first: " .. over.kind)
  assert(over.reason:find("outranks refining", 1, true), over.reason)
end
test_an_over_bound_triage_queue_outranks_refining()

local function test_verdicts_outrank_an_over_bound_triage_queue()
  local goal = make({})
  local checking = make({parent = goal.id, phase = "check", pr = 7})
  local items: {item.Item} = {goal, checking}
  for _ = 1, flow.TRIAGE_LIMIT + 1 do
    items[#items + 1] = make({})
  end
  local action = act.next_action(items)
  assert(action.kind == "review" and action.item.id == checking.id,
    "check is still the rightmost phase: " .. action.kind)
end
test_verdicts_outrank_an_over_bound_triage_queue()

-- `check` full of this session's own work is the one state where the
-- two halves of the claim rule meet: no verdict this session may write
-- drains the phase, and the WIP gate refuses every handover into it.
-- Naming `finish` there would name a move the gate rejects, and asking
-- again would name it again — the loop would never terminate.
local function test_a_full_check_of_its_own_is_not_a_finish_action()
  local root = make({})
  local items: {item.Item} = {root}
  for _ = 1, flow.LIMITS["check"] do
    items[#items + 1] = make({parent = root.id, phase = "check", pr = 7,
        claim = "session-A"})
  end
  items[#items + 1] = make({parent = root.id, phase = "do",
      claim = "session-A"})
  local action = act.next_action(items, "session-A")
  assert(action.kind == "none",
    "the handover would be refused, so it is not offered: " .. action.kind)
  assert(action.reason:find("another session writes a verdict", 1, true),
    "and the reason says what would unstick it: " .. action.reason)
end
test_a_full_check_of_its_own_is_not_a_finish_action()

-- Refusing to hand over is not refusing to work: the intake half is
-- untouched by a full `check`, and stalling there instead would be the
-- same lost session by another route.
local function test_a_full_check_still_leaves_the_intake_half()
  local root = make({})
  local items: {item.Item} = {root}
  for _ = 1, flow.LIMITS["check"] do
    items[#items + 1] = make({parent = root.id, phase = "check", pr = 7,
        claim = "session-A"})
  end
  -- The `do` item is what makes this a real distinction: without the
  -- guard the ordering stops here and names a handover the gate would
  -- refuse, never reaching the refinement below it.
  items[#items + 1] = make({parent = root.id, phase = "do",
      claim = "session-A"})
  local planning = make({parent = root.id, phase = "plan"})
  items[#items + 1] = planning
  local action = act.next_action(items, "session-A")
  assert(action.kind == "refine" and action.item.id == planning.id,
    "refinement is still real work: " .. action.kind)
end
test_a_full_check_still_leaves_the_intake_half()

-- `pull` skips a blocked ready item, so refining one manufactures
-- inventory the other end of the ordering will not take.
local function test_refinement_skips_a_blocked_plan_item()
  local root = make({})
  local blocker = make({parent = root.id, phase = "do", claim = "session-B"})
  local blocked = make({parent = root.id, phase = "plan",
      blocked_by = blocker.id})
  local free = make({parent = root.id, phase = "plan"})
  local items: {item.Item} = {root, blocker, blocked, free}
  local action = act.next_action(items, "session-A")
  assert(action.kind == "refine" and action.item.id == free.id,
    "the older blocked item is skipped for the free one: " .. action.kind)
  assert(action.reason:find("1 blocked and skipped", 1, true),
    "and the reason says how many it stepped over: " .. action.reason)
end
test_refinement_skips_a_blocked_plan_item()

local function test_every_plan_item_blocked_falls_through()
  local idle = make({})
  local driven = make({beats = idle.id})
  local blocker = make({parent = driven.id, phase = "do", claim = "session-B"})
  local blocked = make({parent = driven.id, phase = "plan",
      blocked_by = blocker.id})
  local items: {item.Item} = {idle, driven, blocker, blocked}
  local action = act.next_action(items, "session-A")
  assert(action.kind == "intake" and action.item.id == idle.id,
    "nothing refinable, so the idle root is decomposed: " .. action.kind)
end
test_every_plan_item_blocked_falls_through()

-- `do` full of other sessions' claims binds against this session: an
-- unheld item would have been finished above, so reaching the pull
-- branch here means the move into `do` would be refused.
local function test_a_full_do_of_others_claims_is_not_a_pull()
  local root = make({})
  local items: {item.Item} = {root}
  for _ = 1, flow.LIMITS["do"] do
    items[#items + 1] = make({parent = root.id, phase = "do",
        claim = "session-B"})
  end
  items[#items + 1] = make({parent = root.id, phase = "ready"})
  local action = act.next_action(items, "session-A")
  assert(action.kind ~= "pull",
    "the pull would be refused, so it is not offered: " .. action.kind)
  assert(action.kind == "none" and action.reason:find("@session-B", 1, true),
    "and the held slots are named: " .. action.reason)
end
test_a_full_do_of_others_claims_is_not_a_pull()

-- Pulling while `check` is full manufactures work whose only exit is a
-- handover the gate refuses: the item enters `do` and stops there.
-- Finishing beats starting, and a start that cannot finish is not one.
local function test_a_full_check_stops_the_pull_too()
  local root = make({})
  local items: {item.Item} = {root}
  for _ = 1, flow.LIMITS["check"] do
    items[#items + 1] = make({parent = root.id, phase = "check", pr = 7,
        claim = "session-A"})
  end
  items[#items + 1] = make({parent = root.id, phase = "ready"})
  local action = act.next_action(items, "session-A")
  assert(action.kind ~= "pull",
    "nothing pulls into a do it cannot hand over: " .. action.kind)
end
test_a_full_check_stops_the_pull_too()

-- A claim is a lock whose holder may have died: past the lease the
-- ordering offers the item to whoever asks, the way it already offers
-- rework. Without ages nothing reads as stale, so callers with no git
-- in reach keep the old behavior.
local function test_a_stale_claim_is_offered_for_takeover()
  local root = make({})
  local theirs = make({parent = root.id, phase = "do", claim = "session-B"})
  local items: {item.Item} = {root, theirs}
  local fresh = act.next_action(items, "session-A")
  assert(fresh.kind == "none",
    "without ages the claim holds: " .. fresh.kind)
  local ages: {string: integer} = {[theirs.id] = 5 * 60 * 60}
  local action = act.next_action(items, "session-A", ages)
  assert(action.kind == "finish" and action.item.id == theirs.id,
    "past the lease the item is anyone's: " .. action.kind)
  assert(action.reason:find("stale", 1, true)
    and action.reason:find("--claim session-A", 1, true),
    "the reason says how to take it over: " .. action.reason)
end
test_a_stale_claim_is_offered_for_takeover()

-- A ready column where everything waits admits no pull however deep
-- it is; the answer names the chain's deepest open blocker instead of
-- silently refining around the stall.
local function test_a_starved_ready_names_its_chain_root()
  local root = make({})
  local bottom = make({parent = root.id, phase = "plan"})
  local middle = make({parent = root.id, phase = "plan",
      blocked_by = bottom.id})
  local waiting = make({parent = root.id, phase = "ready",
      blocked_by = middle.id})
  local items: {item.Item} = {root, bottom, middle, waiting}
  local action = act.next_action(items, "session-A")
  assert(action.kind == "unblock" and action.item.id == bottom.id,
    "the chain root is the target: " .. action.kind)
  assert(action.reason:find("every ready item is blocked", 1, true),
    "and the reason says why: " .. action.reason)
end
test_a_starved_ready_names_its_chain_root()
