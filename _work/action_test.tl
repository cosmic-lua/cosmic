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

-- The distance guard applies here too, so `next` never offers what
-- `take` refuses: a session steps past a diff it built and a decision
-- it specced, alone offered neither and together offered neither, to
-- the one genuine candidate behind them.
local function test_a_builder_or_speccer_review_is_stepped_past()
  local items: {Item} = {}
  local root = placed_root(items)
  local built = make({parent = root.id, claim = "b1", pr = 1,
      builders = "me"})
  local specced = make({parent = root.id, claim = "b2", pr = 2,
      speccers = "me"})
  items[#items + 1] = built
  items[#items + 1] = specced
  local specs = ready_specs(items)
  local nothing = act.next_action(items, specs, "me")
  assert(nothing.kind ~= "review",
    "built and specced diffs are offered to nobody: " .. nothing.kind)
  assert(not nothing.reason:find("under another session's live review",
      1, true),
    "and the reason never blames another session's hold, because it "
    .. "is not one: " .. nothing.reason)

  local reviewable = make({parent = root.id, claim = "b3", pr = 3})
  items[#items + 1] = reviewable
  local stepped = act.next_action(items, specs, "me")
  assert(stepped.kind == "review" and stepped.item.id == reviewable.id,
    "and stepped past to the one genuine candidate: " .. stepped.item.id)
end

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
  specs[unrefined.id] = "## Non-goals\nno Change decided yet\n"
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "pull" and a.item.id == free.id,
    ("blocked and unrefined items are skipped: %s %s"):format(a.kind,
      a.item and a.item.id or ""))
end

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
  -- The terminal answer names the bound, not a decompose errand: a
  -- session sent to make more work while pullable work waits at the
  -- gate would deepen what cannot enter (caught by a scenario eval).
  assert(a.kind == "none", "the honest answer is a stop: " .. a.kind)
  assert(a.reason:find("bound", 1, true)
    and a.reason:find("1 pullable", 1, true),
    "and it names the bound and what it withheld: " .. a.reason)
end

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

local function test_an_open_blocker_holds_the_merge_off_the_offer()
  local items: {Item} = {}
  local root = placed_root(items)
  local peer = make({parent = root.id, claim = "other"})
  local accepted = make({parent = root.id, claim = "who", pr = 7,
      verdict = "accept", blocked_by = peer.id})
  items[#items + 1] = peer
  items[#items + 1] = accepted
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind ~= "finish" or a.item.id ~= accepted.id,
    "a binding blocker holds the merge back: " .. a.kind)
  assert(a.kind == "none",
    "nothing else is offered either: " .. a.kind)
  assert(a.reason:find("accepted item", 1, true)
    and a.reason:find("merges are held", 1, true),
    "the held merge is named: " .. a.reason)
  peer.resolution = "completed"
  local b = act.next_action(items, specs, "me")
  assert(b.kind == "finish" and b.item.id == accepted.id,
    "ending the blocker returns it to the finish offer: " .. b.kind)
end

local function test_a_blocked_building_item_is_still_offered()
  local items: {Item} = {}
  local root = placed_root(items)
  local peer = make({parent = root.id, claim = "other"})
  local building = make({parent = root.id, claim = "me",
      blocked_by = peer.id})
  items[#items + 1] = peer
  items[#items + 1] = building
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "finish" and a.item.id == building.id,
    "a blocker records landing order, not a build to finish: " .. a.kind)
end

-- A lane repair is the pull that cannot wait: it outranks ordinary
-- pulls, but a merge, a review or a builder's own rework still land
-- ahead of it — a broken lane never outranks landing what is already
-- accepted.
local function test_lane_repair_outranks_ordinary_pulls()
  local items: {Item} = {}
  local root = placed_root(items)
  local repair = make({parent = root.id, lane = "release.yml"})
  local ordinary = make({parent = root.id})
  items[#items + 1] = repair
  items[#items + 1] = ordinary
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "pull" and a.item.id == repair.id,
    "the repair is offered ahead of the ordinary pull: " .. a.kind
    .. " " .. (a.item and a.item.id or ""))
  assert(a.reason == "lane repair: release.yml",
    "the reason names the lane: " .. a.reason)
end

local function test_a_pending_merge_still_outranks_the_repair()
  local items: {Item} = {}
  local root = placed_root(items)
  local accepted = make({parent = root.id, claim = "who", pr = 1,
      verdict = "accept"})
  local repair = make({parent = root.id, lane = "release.yml"})
  items[#items + 1] = accepted
  items[#items + 1] = repair
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "finish" and a.item.id == accepted.id,
    "landing what is already accepted still comes first: " .. a.kind)
end

-- The wall the spec pins for merge holds for review too: an open PR
-- with no verdict yet outranks a red-lane repair, the same as an
-- accepted one does. Pinned separately from the merge case because
-- the ordering rungs are independent code paths in `phased_action` —
-- reverting only the repair-offer block above the review loop leaves
-- the merge test green while this one goes red.
local function test_a_pending_review_still_outranks_the_repair()
  local items: {Item} = {}
  local root = placed_root(items)
  local reviewable = make({parent = root.id, claim = "who", pr = 2})
  local repair = make({parent = root.id, lane = "release.yml"})
  items[#items + 1] = reviewable
  items[#items + 1] = repair
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "review" and a.item.id == reviewable.id,
    "a verdict awaiting a PR still comes before a lane repair: " .. a.kind)
end

-- The doing bound never holds a lane repair back: `flow.doing_refusal`
-- admits it at the same bound it refuses an ordinary take at, and
-- `next_action` still offers it as the pull rather than falling
-- through to the bound's own terminal "none".
local function test_lane_repair_is_admitted_at_the_doing_bound()
  local items: {Item} = {}
  local root = placed_root(items)
  for k = 1, flow.DOING_LIMIT do
    items[#items + 1] = make({parent = root.id,
        claim = ("wake-%d"):format(k)})
  end
  local repair = make({parent = root.id, lane = "fuzz.yml"})
  items[#items + 1] = repair
  assert(flow.doing_refusal(items) ~= nil,
    "the bound still refuses an ordinary take")
  assert(flow.doing_refusal(items, repair) == nil,
    "but never a lane repair's own take")
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "pull" and a.item.id == repair.id,
    "the repair is still offered at the bound: " .. a.kind)
end

-- A blocked repair waits on its blocker exactly like any other pull —
-- the lane class changes ordering, never the block/take relationship.
local function test_a_blocked_repair_does_not_jump_its_blocker()
  local items: {Item} = {}
  local root = placed_root(items)
  local blocker = make({parent = root.id, claim = "other"})
  local repair = make({parent = root.id, lane = "release.yml",
      blocked_by = blocker.id})
  items[#items + 1] = blocker
  items[#items + 1] = repair
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind ~= "pull" or a.item.id ~= repair.id,
    "a blocked repair is not offered as the pull: " .. a.kind)
end

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

-- A research handover is offered as the review, ahead of a todo pull,
-- by the same rung a PR's verdict is — `substate` is the one
-- declaration, so the rung needed no edit to see it — and its own
-- builder is stepped past it the same way.
local function test_a_research_handover_is_offered_as_the_review()
  local items: {Item} = {}
  local root = placed_root(items)
  local handed = make({parent = root.id, claim = "who", builders = "who",
      result = ("ab"):rep(32)})
  local fresh = make({parent = root.id})
  items[#items + 1] = handed
  items[#items + 1] = fresh
  local specs = ready_specs(items)
  local a = act.next_action(items, specs, "me")
  assert(a.kind == "review" and a.item.id == handed.id,
    "the handover awaits a verdict, and verdicts come before new work: "
    .. a.kind)
  local b = act.next_action(items, specs, "who")
  assert(b.kind ~= "review", "its own builder is never offered the review: "
    .. b.kind)
end

-- The review reason names what awaits the verdict — a diff or a
-- research handover — so the reviewer reaches for `--pr`/`--head` or
-- for neither. The PR wording is the one it always was.
local function test_the_review_reason_names_what_awaits_the_verdict()
  local items: {Item} = {}
  local root = placed_root(items)
  local handed = make({parent = root.id, claim = "who", builders = "who",
      result = ("ab"):rep(32)})
  items[#items + 1] = handed
  local a = act.next_action(items, ready_specs(items), "me")
  assert(a.kind == "review" and a.item.id == handed.id, a.kind)
  assert(a.reason:find("a research handover awaits a verdict", 1, true),
    "a handover is named as one: " .. a.reason)
  assert(not a.reason:find("PR", 1, true),
    "and no PR is claimed for it: " .. a.reason)
  local diffs: {Item} = {}
  local other = placed_root(diffs)
  local diff = make({parent = other.id, claim = "who", pr = 2})
  diffs[#diffs + 1] = diff
  local b = act.next_action(diffs, ready_specs(diffs), "me")
  assert(b.kind == "review" and b.item.id == diff.id, b.kind)
  assert(b.reason == "a PR awaits a verdict — verdicts before new work",
    "a diff's reason is unchanged: " .. b.reason)
end
