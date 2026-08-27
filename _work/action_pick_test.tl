#!/usr/bin/env cosmic
-- The candidate list and its concurrency behavior: blocked items are
-- skipped wherever the WIP limits still hold and escalated the moment
-- one binds, alternates fan sessions across items no judgment
-- separates, and the per-session seed decorrelates the tied remainder
-- without touching any judged order. Split from action_test.tl, which
-- pins the single-answer ordering, by the 500-line file limit.

local check = require("cosmic.check")
local flow = require("_work.flow")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local prio = require("_work.priority")
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

-- The starvation rule fires ahead of intake exactly when it binds:
-- every ready item blocked AND ready at its limit, so no refinement
-- can feed a pullable item past them.
local function test_starvation_outranks_intake_only_at_the_limit()
  local root = make({})
  local gate = make({parent = root.id, phase = "backlog"})
  local blocked: {item.Item} = {}
  for _ = 1, flow.LIMITS["ready"] do
    blocked[#blocked + 1] = make({parent = root.id, phase = "ready",
        blocked_by = gate.id})
  end
  local refinable = make({parent = root.id, phase = "plan"})
  local items: {item.Item} = {root, gate, refinable}
  for _, i in ipairs(blocked) do
    items[#items + 1] = i
  end
  local action = act.next_action(items, "session-A")
  assert(action.kind == "unblock" and action.item.id == gate.id,
    "at the limit the chain root outranks refinement: " .. action.kind)
  assert(action.reason:find("ready is at its limit", 1, true),
    "and the reason names the binding: " .. action.reason)
end
test_starvation_outranks_intake_only_at_the_limit()

-- ...and when intake itself is empty, the blocked chain's root is
-- still named as the fallback rather than a silent `none`.
local function test_starvation_is_the_fallback_when_intake_is_empty()
  local root = make({})
  local gate = make({parent = root.id, phase = "backlog"})
  local waiting = make({parent = root.id, phase = "ready",
      blocked_by = gate.id})
  local items: {item.Item} = {root, gate, waiting}
  local action = act.next_action(items, "session-A")
  -- `gate` sits in backlog unblocked, so intake promotes it — which
  -- IS working the chain root. Only with it committed does the
  -- fallback fire.
  assert(action.kind == "promote" and action.item.id == gate.id,
    "intake works the chain root first: " .. action.kind)
  gate.phase = "do"
  gate.claim = "session-B"
  local held = act.next_action(items, "session-A")
  assert(held.kind == "unblock" and held.item.id == gate.id,
    "with intake empty the chain root is the fallback: " .. held.kind)
  assert(held.reason:find("intake holds nothing", 1, true),
    "and the reason says intake had nothing: " .. held.reason)
end
test_starvation_is_the_fallback_when_intake_is_empty()

-- A blocked `do` item cannot be finished, so it is stepped over — it
-- keeps its slot for the limit, and the pull proceeds while room
-- remains.
local function test_a_blocked_do_item_is_skipped_for_the_pull()
  local root = make({})
  local gate = make({parent = root.id, phase = "backlog"})
  local parked = make({parent = root.id, phase = "do",
      claim = "session-A", blocked_by = gate.id})
  local ready = make({parent = root.id, phase = "ready"})
  local items: {item.Item} = {root, gate, parked, ready}
  local action = act.next_action(items, "session-A")
  assert(action.kind == "pull" and action.item.id == ready.id,
    "the blocked do item is not offered as finish: " .. action.kind)
end
test_a_blocked_do_item_is_skipped_for_the_pull()

-- The candidate list crosses rungs when the top one is thin: one
-- review and two pullable items yield the review first with the pulls
-- behind it, and the pull tail respects `do`'s free slots.
local function test_alternates_cross_rungs_and_respect_do_room()
  local root = make({})
  local judged = make({parent = root.id, phase = "check", pr = 7,
      claim = "session-B"})
  local ready_one = make({parent = root.id, phase = "ready"})
  local ready_two = make({parent = root.id, phase = "ready"})
  local ready_three = make({parent = root.id, phase = "ready"})
  local items: {item.Item} = {root, judged, ready_one, ready_two, ready_three}
  -- Fill do to one free slot: the pull tail must hold exactly one.
  for k = 1, flow.LIMITS["do"] - 1 do
    items[#items + 1] = make({parent = root.id, phase = "do",
        claim = ("other-%d"):format(k)})
  end
  local action = act.next_action(items, "session-A")
  assert(action.kind == "review" and action.item.id == judged.id,
    "the review leads: " .. action.kind)
  local alts = action.alternates or {}
  assert(#alts == 1 and alts[1].kind == "pull",
    ("one free do slot admits exactly one pull alternate, got %d")
    :format(#alts))
end
test_alternates_cross_rungs_and_respect_do_room()

-- With room, the alternates carry the pulls in queue order, capped at
-- the candidate bound.
local function test_alternates_list_pulls_up_to_the_bound()
  local root = make({})
  local items: {item.Item} = {root}
  local ready: {item.Item} = {}
  for _ = 1, 6 do
    local r = make({parent = root.id, phase = "ready"})
    ready[#ready + 1] = r
    items[#items + 1] = r
  end
  local action = act.next_action(items, "session-A")
  assert(action.kind == "pull", "pull leads: " .. action.kind)
  local alts = action.alternates or {}
  assert(#alts == 3, ("the bound caps primary plus alternates at four, "
      .. "got %d alternates"):format(#alts))
  for _, alt in ipairs(alts) do
    assert(alt.kind == "pull", "every alternate is a pull")
  end
end
test_alternates_list_pulls_up_to_the_bound()

-- The seed replaces only the final age tie-break: items nothing
-- separates order differently per seed, deterministically per seed,
-- and an unseeded walk keeps age order.
local function test_the_seed_fans_tied_items_out_deterministically()
  local root = make({})
  local items: {item.Item} = {root}
  local tied: {item.Item} = {}
  for _ = 1, 8 do
    local r = make({parent = root.id, phase = "ready"})
    tied[#tied + 1] = r
    items[#items + 1] = r
  end
  local pos = prio.positions(items)
  local plain = prio.sorted(tied, pos)
  assert(plain[1].id < plain[2].id, "unseeded keeps age order")
  local seeded_a = prio.sorted(tied, pos, "session-A")
  local seeded_b = prio.sorted(tied, pos, "session-B")
  local again_a = prio.sorted(tied, pos, "session-A")
  for k, i in ipairs(seeded_a) do
    assert(again_a[k].id == i.id, "the same seed walks the same order")
  end
  local differs = false
  for k, i in ipairs(seeded_a) do
    if seeded_b[k].id ~= i.id then
      differs = true
    end
  end
  assert(differs, "different seeds walk different orders over a tie")
  local first_a = act.next_action(items, "session-A", {}, "session-A")
  local first_b = act.next_action(items, "session-B", {}, "session-B")
  assert(first_a.kind == "pull" and first_b.kind == "pull")
  assert(first_a.item.id ~= first_b.item.id,
    "two sessions asking one board start on different tied items")
end
test_the_seed_fans_tied_items_out_deterministically()

-- A `do` column where every item waits used to fall through to a
-- terminal whose every clause was about other phases — a silent stall
-- with a wrong reason. It now names the blocked chain's root, the
-- same promise the starved ready keeps.
local function test_a_do_full_of_blocked_items_names_its_chain()
  local root = make({})
  local blocker = make({parent = root.id})
  local items: {item.Item} = {root, blocker}
  for _ = 1, flow.LIMITS["do"] do
    items[#items + 1] = make({parent = root.id, phase = "do",
        claim = "session-A", blocked_by = blocker.id})
  end
  local action = act.next_action(items, "session-A")
  assert(action.kind == "unblock" and action.item.id == blocker.id,
    "the blocked do column names its chain root: " .. action.kind
    .. " — " .. action.reason)
  assert(action.reason:find("do item(s) wait on open blockers", 1, true),
    "and the reason says which stall this is: " .. action.reason)
end
test_a_do_full_of_blocked_items_names_its_chain()

print("all candidate-pick tests passed")
